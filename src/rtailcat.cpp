// Native layer for rtailcat: wraps the tailcat C ABI (tailcat.h, ABI v1).
//
// Blocking tc_* calls always run on a worker thread with a real cancellation
// token. The worker never touches R; results are stored in plain C++ fields
// and converted to R objects on the main thread, either directly (sync) or
// from a continuation scheduled on later's event loop (async).
//
// Reads, and writes (including close_write), on one connection run in
// submission order: each direction has a FIFO lane, and a job's worker waits
// for its turn before calling into tailcat. Upstream only orders same-direction
// calls by the order its threads arrive, which is not the submission order.

#include <cpp11.hpp>
#include <later_api.h>

#include "tailcat.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <climits>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <system_error>
#include <thread>
#include <unordered_set>
#include <vector>

#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#endif

using namespace cpp11::literals;

namespace {

long current_pid() {
#ifdef _WIN32
  return static_cast<long>(_getpid());
#else
  return static_cast<long>(getpid());
#endif
}

// The Go runtime does not survive fork(); remember which process loaded us.
const long load_pid = current_pid();

bool in_forked_child() { return current_pid() != load_pid; }

void fork_guard() {
  if (in_forked_child()) {
    cpp11::stop(
        "rtailcat cannot be used in a forked child process (for example "
        "inside parallel::mclapply()): the embedded Go runtime does not "
        "survive fork. Use a separate R process instead.");
  }
}

// cpp11 has no public type predicates, so ask base R.
template <typename... Args>
bool base_predicate(const char* name, const Args&... args) {
  return cpp11::as_cpp<bool>(cpp11::package("base")[name](args...));
}

// Larger than any UDP datagram (at most 1232 bytes), and TCP reads may be
// short, so capping the buffer never changes what a caller can observe.
constexpr size_t max_read_size = 65536;

// timeout = 0 is a poll. The ABI has no true poll (a zero timeout_ns is an
// already expired token), so a poll gets this short real deadline instead.
constexpr int64_t poll_window_ns = INT64_C(5000000);

// Network codes of tailcat.h (TC_TCP, TC_UDP).
constexpr int32_t network_tcp = 1;

// Operations holding a worker thread, running or waiting in a lane. The main
// thread increments it just before starting the thread (after comparing it
// with the limit), and the thread decrements it once it no longer needs
// anything from tailcat, so a racing decrement can only make the check
// conservative.
std::atomic<long> operations_in_flight(0);

// ---- Handles ---------------------------------------------------------------

enum Kind {
  KIND_CLIENT = 1,
  KIND_SERVER = 2,
  KIND_LISTENER = 4,
  KIND_CONNECTION = 8,
  KIND_ANY = 15
};

const char* kind_class(int kind) {
  switch (kind) {
    case KIND_CLIENT: return "rtc_client";
    case KIND_SERVER: return "rtc_server";
    case KIND_LISTENER: return "rtc_listener";
    default: return "rtc_connection";
  }
}

struct Job;

// Jobs in submission order. The front job is the one allowed to call into
// tailcat; the others wait on cv. Shared with workers, so it holds no R
// objects.
struct Lane {
  std::mutex m;
  std::condition_variable cv;
  std::deque<Job*> jobs;
};

enum LaneId { LANE_READ = 0, LANE_WRITE = 1 };

struct Handle {
  Handle(tc_handle h_, int kind_, int32_t network_)
      : h(h_), closed(false), write_shut(false), kind(kind_), network(network_) {
    if (kind == KIND_CONNECTION) {
      lanes[LANE_READ] = std::make_shared<Lane>();
      lanes[LANE_WRITE] = std::make_shared<Lane>();
    }
  }
  tc_handle h;
  std::atomic<bool> closed;
  // Connections only: set once close_write has succeeded. tc_info panics
  // inside tailcat once both directions are shut down, and print methods use
  // this to avoid triggering that.
  std::atomic<bool> write_shut;
  int kind;
  // Listeners and connections only; 0 for clients and servers.
  int32_t network;
  std::shared_ptr<Lane> lanes[2];
};

// Wakes queued jobs so they notice the handle is closed.
void wake_lanes(Handle* p) {
  for (auto& lane : p->lanes) {
    if (lane) {
      std::lock_guard<std::mutex> lock(lane->m);
      lane->cv.notify_all();
    }
  }
}

// cpp11 external pointers carry no tag, so the addresses of live handles are
// tracked to reject foreign external pointers before dereferencing them.
// Main thread only (entry points and R finalizers).
std::unordered_set<const Handle*>& live_handles() {
  static std::unordered_set<const Handle*> set;
  return set;
}

void handle_delete(Handle* p) {
  live_handles().erase(p);
  if (!in_forked_child() && !p->closed.exchange(true)) {
    tc_close(p->h, nullptr);
  }
  delete p;
}

using handle_ptr = cpp11::external_pointer<Handle, handle_delete>;

// Takes ownership of h. If this throws before the external pointer exists, h
// is unchanged and the caller must close it; once the pointer exists, h is 0
// and the pointer's finalizer closes the handle, even if a later step throws.
cpp11::sexp make_handle(tc_handle& h, int kind, int32_t network = 0) {
  std::unique_ptr<Handle> owned(new Handle(h, kind, network));
  live_handles().insert(owned.get());
  cpp11::sexp out;
  try {
    handle_ptr ptr(owned.get(), true, false);
    owned.release();
    h = 0;
    out = cpp11::sexp(ptr);
  } catch (...) {
    if (owned) {
      live_handles().erase(owned.get());
    }
    throw;
  }
  out.attr("class") = {kind_class(kind), "rtc_handle"};
  return out;
}

void close_quietly(tc_handle& h) {
  if (h != 0 && !in_forked_child()) {
    tc_close(h, nullptr);
  }
  h = 0;
}

// Returns the handle struct, or nullptr if the handle is closed or was
// invalidated (for example by saving and reloading the workspace).
Handle* arg_handle(const cpp11::sexp& x, int kinds, const char* what) {
  Handle* p = nullptr;
  try {
    p = handle_ptr(x).get();
  } catch (const cpp11::type_error&) {
    cpp11::stop("`%s` must be an rtailcat handle", what);
  }
  if (p == nullptr) {
    if (!base_predicate("inherits", x, "rtc_handle")) {
      cpp11::stop("`%s` must be an rtailcat handle", what);
    }
    return nullptr;
  }
  if (live_handles().count(p) == 0) {
    cpp11::stop("`%s` must be an rtailcat handle", what);
  }
  if ((p->kind & kinds) == 0) {
    cpp11::stop("`%s` is an %s handle, which is not supported here", what,
                kind_class(p->kind));
  }
  if (p->closed.load()) {
    return nullptr;
  }
  return p;
}

// ---- Results ---------------------------------------------------------------

// A byte count as an integer when it fits, otherwise a double.
cpp11::sexp byte_count(double bytes) {
  return bytes <= INT_MAX ? cpp11::as_sexp(static_cast<int>(bytes)) : cpp11::as_sexp(bytes);
}

// message is tailcat's own text, or text in the same style, and may be empty;
// R/errors.R turns it into the detail line of the condition. Text that does
// not come from tailcat starts with "rtailcat: ".
cpp11::sexp make_error(int status, const std::string& message, double bytes) {
  cpp11::sexp out = cpp11::writable::list({
      "status"_nm = status,
      "message"_nm = message,
      "bytes"_nm = byte_count(bytes),
  });
  out.attr("class") = "rtc_error";
  return out;
}

// Copy a tc_*-allocated string and release it with tc_free.
void take_string(char*& p, std::string& dst) {
  if (p != nullptr) {
    dst.assign(p);
    tc_free(p);
    p = nullptr;
  }
}

// ---- Jobs ------------------------------------------------------------------

enum class Op {
  ServerStart,
  ServerListen,
  ListenerAccept,
  ClientDial,
  ConnRead,
  ConnWrite,
  ConnCloseWrite,
  Info,
  ClientPing,
  ClientDiscoPing,
  ServerAllowClient,
  Drain,
  AddressResolve
};

using steady = std::chrono::steady_clock;

// Shared between the main thread and the worker, so it holds no R objects:
// the worker may drop the last reference.
struct Job {
  explicit Job(Op op_) : op(op_) {}

  Op op;

  // Inputs, copied before the worker starts.
  Handle* handle = nullptr;
  tc_handle h = 0;
  tc_token token = 0;
  uint16_t port = 0;
  int32_t network = 0;
  std::string s1;
  std::string s2;
  std::vector<unsigned char> buf;
  size_t n = 0;
  int loop_id = 0;
  // A TCP read with timeout = 0: the worker asks tc_conn_readable() first and
  // reads (with a token without deadline) only if data or end of stream is
  // already there, so the poll never races its own short deadline.
  bool probe = false;

  // Ordering. lane is set for connection reads and writes; queued and
  // cancel_requested are guarded by lane->m. The deadline mirrors the token's,
  // so a job that times out while waiting for its turn ends without running.
  std::shared_ptr<Lane> lane;
  bool queued = false;
  bool cancel_requested = false;
  bool has_deadline = false;
  steady::time_point deadline;

  // Outputs, written by the worker only.
  int32_t status = TC_OK;
  std::string err;
  tc_handle out_h = 0;
  std::string out_s;
  std::unique_ptr<unsigned char[]> rbuf;
  size_t count = 0;
  int32_t out_i = 0;

  // Set by the worker when it is finished with the job.
  std::mutex m;
  std::condition_variable cv;
  bool done = false;
};

bool job_done(Job& j) {
  std::lock_guard<std::mutex> lock(j.m);
  return j.done;
}

// The R-owning half of an async job. Created in submit() and destroyed by
// async_complete(), both on the main thread; the worker only forwards the
// pointer to later::later() and never dereferences it.
struct AsyncCall {
  AsyncCall(std::shared_ptr<Job> job_, cpp11::sexp handle_, cpp11::function callback_)
      : job(std::move(job_)), handle(std::move(handle_)), callback(std::move(callback_)) {}

  std::shared_ptr<Job> job;
  // Keeps the R handle, and so job->handle, alive until the callback runs.
  cpp11::sexp handle;
  cpp11::function callback;
};

// ---- Cancel handles --------------------------------------------------------

// What an async entry point returns. The worker closes the token when the job
// ends, and token handles are never reused, so a late tc_token_cancel just
// returns TC_CLOSED. job is weak, so the handle never keeps a job alive and
// can only ever reach the job it was made for. token is 0 (TC_NO_CANCEL) for
// a job that never started.
struct Cancel {
  Cancel(tc_token token_, std::weak_ptr<Job> job_) : token(token_), job(std::move(job_)) {}
  tc_token token;
  std::weak_ptr<Job> job;
};

std::unordered_set<const Cancel*>& live_cancels() {
  static std::unordered_set<const Cancel*> set;
  return set;
}

void cancel_delete(Cancel* p) {
  live_cancels().erase(p);
  delete p;
}

using cancel_ptr = cpp11::external_pointer<Cancel, cancel_delete>;

cpp11::sexp make_cancel(tc_token token, std::weak_ptr<Job> job) {
  std::unique_ptr<Cancel> owned(new Cancel(token, std::move(job)));
  live_cancels().insert(owned.get());
  cpp11::sexp out;
  try {
    cancel_ptr ptr(owned.get(), true, false);
    owned.release();
    out = cpp11::sexp(ptr);
  } catch (...) {
    if (owned) {
      live_cancels().erase(owned.get());
    }
    throw;
  }
  out.attr("class") = "rtc_cancel";
  return out;
}

// Returns true if the job was still waiting for its turn or its token was
// still open (it was running, or had just finished and not yet released it).
bool request_cancel(Job& j) {
  bool signaled = false;
  if (j.lane) {
    std::lock_guard<std::mutex> lock(j.lane->m);
    if (j.queued) {
      j.cancel_requested = true;
      signaled = true;
      j.lane->cv.notify_all();
    }
  }
  if (j.token != 0 && tc_token_cancel(j.token, nullptr) == TC_OK) {
    signaled = true;
  }
  return signaled;
}

bool arg_callback(const cpp11::sexp& callback) {
  if (base_predicate("is.null", callback)) {
    return false;
  }
  if (!base_predicate("is.function", callback)) {
    cpp11::stop("`callback` must be NULL or a function");
  }
  return true;
}

// ---- Execution (worker thread) ---------------------------------------------

void execute(Job& j) {
  char* err = nullptr;
  char* out = nullptr;
  switch (j.op) {
    case Op::ServerStart:
      j.status = tc_server_start(j.h, j.token, &err);
      break;
    case Op::ServerListen:
      j.status = tc_server_listen(j.h, j.token, j.port, j.network, &j.out_h, &err);
      break;
    case Op::ListenerAccept:
      j.status = tc_listener_accept(j.h, j.token, &j.out_h, &err);
      break;
    case Op::ClientDial:
      j.status = tc_client_dial(j.h, j.token, j.port, j.network, &j.out_h, &err);
      break;
    case Op::ConnRead:
      if (j.n > 0) {
        // Left uninitialized: tailcat fills the first count bytes.
        j.rbuf.reset(new (std::nothrow) unsigned char[j.n]);
        if (!j.rbuf) {
          j.status = TC_FAILURE;
          j.err = "rtailcat: could not allocate the read buffer";
          break;
        }
      }
      j.status = tc_conn_read(j.h, j.token, j.rbuf.get(), j.n, &j.count, &err);
      break;
    case Op::ConnWrite: {
      const size_t len = j.buf.size();
      size_t total = 0;
      int32_t status = TC_OK;
      do {
        size_t c = 0;
        void* ptr = len > 0 ? j.buf.data() + total : nullptr;
        status = tc_conn_write(j.h, j.token, ptr, len - total, &c, &err);
        total += c;
        if (status != TC_OK) {
          break;
        }
        if (c == 0 && total < len) {
          status = TC_FAILURE;
          j.err = "rtailcat: write made no progress";
          break;
        }
      } while (total < len);
      j.status = status;
      j.count = total;
      break;
    }
    case Op::ConnCloseWrite:
      j.status = tc_conn_close_write(j.h, j.token, &err);
      if (j.status == TC_OK) {
        j.handle->write_shut.store(true);
      }
      break;
    case Op::Info:
      j.status = tc_info(j.h, j.token, &out, &err);
      break;
    case Op::ClientPing:
      j.status = tc_client_ping(j.h, j.token, &j.out_i, &err);
      break;
    case Op::ClientDiscoPing:
      j.status = tc_client_disco_ping(j.h, j.token, &out, &err);
      break;
    case Op::ServerAllowClient:
      j.status = tc_server_allow_client(j.h, j.token, j.s1.data(), &err);
      break;
    case Op::Drain:
      j.status = tc_drain(j.h, j.token, &err);
      break;
    case Op::AddressResolve:
      // tailcat treats an empty derp_map_url like NULL: the default map.
      j.status = tc_address_resolve(j.token, j.s1.data(), j.s2.data(), &out, &err);
      break;
  }
  take_string(out, j.out_s);
  take_string(err, j.err);
}

// Waits until j is at the front of its lane. Returns false, with the job's
// outcome set, if it was canceled, timed out, or its handle was closed first.
bool wait_turn(Job& j) {
  Lane& lane = *j.lane;
  std::unique_lock<std::mutex> lock(lane.m);
  for (;;) {
    if (j.cancel_requested) {
      j.status = TC_CANCELLED;
      j.err = "context canceled";
      return false;
    }
    if (j.handle->closed.load()) {
      j.status = TC_CLOSED;
      return false;
    }
    if (lane.jobs.front() == &j) {
      return true;
    }
    if (j.has_deadline) {
      if (steady::now() >= j.deadline) {
        j.status = TC_TIMEOUT;
        j.err = "context deadline exceeded";
        return false;
      }
      lane.cv.wait_until(lock, j.deadline);
    } else {
      lane.cv.wait(lock);
    }
  }
}

// Returns true if a read would return at once. Otherwise sets the job's
// outcome: a timeout with no message, or the error from tailcat.
bool probe_ready(Job& j) {
  int32_t ready = 0;
  char* err = nullptr;
  int32_t st = tc_conn_readable(j.h, &ready, &err);
  take_string(err, j.err);
  if (st != TC_OK) {
    j.status = st;
    return false;
  }
  if (ready == 0) {
    j.status = TC_TIMEOUT;
    return false;
  }
  return true;
}

void leave_lane(Job& j) {
  Lane& lane = *j.lane;
  std::lock_guard<std::mutex> lock(lane.m);
  auto it = std::find(lane.jobs.begin(), lane.jobs.end(), &j);
  if (it != lane.jobs.end()) {
    lane.jobs.erase(it);
  }
  j.queued = false;
  lane.cv.notify_all();
}

void async_complete(void* data);

// call is null for sync jobs. The worker never dereferences it, so every R
// object it owns is released on the main thread by async_complete().
void worker_main(std::shared_ptr<Job> j, AsyncCall* call) {
  // Nothing may escape a detached thread: std::terminate would end R.
  try {
    if ((!j->lane || wait_turn(*j)) && (!j->probe || probe_ready(*j))) {
      execute(*j);
    }
  } catch (...) {
    j->status = TC_FAILURE;
    j->err = "rtailcat: internal error in the worker thread";
  }
  if (j->lane) {
    leave_lane(*j);
  }
  tc_close(j->token, nullptr);
  // Before the result is published, so a caller who has seen it also sees
  // the count without this job.
  operations_in_flight.fetch_sub(1);
  if (call != nullptr) {
    later::later(async_complete, call, 0, j->loop_id);
  }
  std::lock_guard<std::mutex> lock(j->m);
  j->done = true;
  j->cv.notify_all();
}

// ---- Building results (main thread) ----------------------------------------

cpp11::sexp build_result(Job& j) {
  int status = j.status;
  std::string message = j.err;
  if (status != TC_OK && status != TC_EOF && j.handle != nullptr &&
      j.handle->closed.load()) {
    status = TC_CLOSED;
    message.clear();
  }

  if (j.op == Op::ConnRead) {
    // Bytes are delivered even when an error follows them; the error (or
    // EOF) is reported by the next read.
    if (j.count > 0 || status == TC_OK) {
      cpp11::writable::raws out(static_cast<std::ptrdiff_t>(j.count));
      if (j.count > 0) {
        std::copy(j.rbuf.get(), j.rbuf.get() + j.count, out.begin());
      }
      return out;
    }
    if (status == TC_EOF) {
      return cpp11::sexp();
    }
    return make_error(status, message, 0);
  }

  if (status != TC_OK) {
    double bytes = j.op == Op::ConnWrite ? static_cast<double>(j.count) : 0;
    return make_error(status, message, bytes);
  }

  switch (j.op) {
    case Op::ServerListen:
      return make_handle(j.out_h, KIND_LISTENER, j.network);
    case Op::ListenerAccept:
    case Op::ClientDial:
      return make_handle(j.out_h, KIND_CONNECTION, j.network);
    case Op::ConnWrite:
      return byte_count(static_cast<double>(j.count));
    case Op::Info:
    case Op::ClientDiscoPing:
    case Op::AddressResolve:
      return cpp11::as_sexp(j.out_s);
    case Op::ClientPing:
      return cpp11::as_sexp(j.out_i);
    default:
      return cpp11::sexp();
  }
}

// A handle produced by the worker is owned by the job until build_result()
// hands it to R, so close it if building the result fails.
cpp11::sexp take_result(Job& j) {
  try {
    return build_result(j);
  } catch (...) {
    close_quietly(j.out_h);
    throw;
  }
}

// ---- Async completion (main thread, from later's event loop) ---------------

// Async calls that complete on a loop other than later's global loop. If that
// loop is destroyed before the completion runs, later drops the completion
// without running it; sweep_private() then delivers it on the global loop.
std::unordered_set<AsyncCall*>& private_calls() {
  static std::unordered_set<AsyncCall*> set;
  return set;
}

bool sweep_scheduled = false;

void sweep_private(void*);

void schedule_sweep() {
  if (!sweep_scheduled && !private_calls().empty()) {
    later::later(sweep_private, nullptr, 1.0, GLOBAL_LOOP);
    sweep_scheduled = true;
  }
}

int current_loop_id() {
  cpp11::environment loop(cpp11::package("later")["current_loop"]());
  return cpp11::as_cpp<int>(loop["id"]);
}

// later::exists_loop() only reads `$id`. Holding the loop object itself would
// keep a loop the user dropped from ever being cleaned up.
bool loop_exists(int id) {
  cpp11::writable::list probe({"id"_nm = id});
  return cpp11::as_cpp<bool>(cpp11::package("later")["exists_loop"](probe));
}

void async_complete(void* data) {
  std::unique_ptr<AsyncCall> call(static_cast<AsyncCall*>(data));
  private_calls().erase(call.get());
  // Nothing may unwind into later's C++ frames. rtc_callback() in R/utils.R
  // catches every R error in the callback, so an exception here is an
  // allocation failure, an interrupt, or an R error from a callback not built
  // by rtc_callback() (which R has already printed, as at top level).
  // take_result() has closed any produced handle that never reached R, so
  // the exception is dropped, as a top-level R error would be.
  try {
    cpp11::sexp result = take_result(*call->job);
    call->callback(result);
  } catch (...) {
  }
}

void sweep_private(void*) {
  sweep_scheduled = false;
  try {
    std::vector<AsyncCall*> orphaned;
    for (AsyncCall* call : private_calls()) {
      // Once the job is done its completion has been posted, and a loop that
      // no longer exists never comes back, so it can only run from here.
      if (job_done(*call->job) && !loop_exists(call->job->loop_id)) {
        orphaned.push_back(call);
      }
    }
    for (AsyncCall* call : orphaned) {
      async_complete(call);
    }
  } catch (...) {
  }
  schedule_sweep();
}

// Main thread. Schedules the completion of an async job on its loop.
void post_complete(AsyncCall* call) {
  if (call->job->loop_id != GLOBAL_LOOP) {
    private_calls().insert(call);
    schedule_sweep();
  }
}

// ---- Dispatch (main thread) ------------------------------------------------

// Completes a job without running it.
cpp11::sexp finish_early(Job& j, std::unique_ptr<AsyncCall>& call, int status,
                         const std::string& message) {
  j.status = status;
  j.err = message;
  {
    std::lock_guard<std::mutex> lock(j.m);
    j.done = true;
  }
  if (call) {
    cpp11::sexp cancel = make_cancel(0, std::weak_ptr<Job>());
    AsyncCall* raw = call.release();
    post_complete(raw);
    later::later(async_complete, raw, 0, j.loop_id);
    return cancel;
  }
  return take_result(j);
}

bool timeout_to_ns(double timeout, int64_t* out) {
  if (std::isnan(timeout) || timeout < 0) {
    return false;
  }
  if (timeout == 0) {
    *out = poll_window_ns;
  } else if (std::isinf(timeout) || timeout * 1e9 >= 9.2e18) {
    *out = -1;
  } else {
    *out = static_cast<int64_t>(timeout * 1e9);
  }
  return true;
}

// The limit comes from the rtailcat.max_operations option, read (and
// validated by max_operations_option() in R/utils.R) at every submission. NA
// means the option is invalid; Inf means no limit.
bool within_operation_limit(std::string* problem) {
  double limit = cpp11::as_cpp<double>(cpp11::package("rtailcat")["max_operations_option"]());
  if (std::isnan(limit)) {
    *problem =
        "rtailcat: the rtailcat.max_operations option must be a single positive whole "
        "number or Inf";
    return false;
  }
  long in_flight = operations_in_flight.load();
  if (std::isinf(limit) || static_cast<double>(in_flight) < limit) {
    return true;
  }
  *problem = "rtailcat: the limit of " + std::to_string(static_cast<long long>(limit)) +
             " operations in flight (running or queued) was reached; it is set by the "
             "rtailcat.max_operations option. Wait for operations to finish, cancel "
             "some, or raise the limit";
  return false;
}

// A job that has something to hand back: a result an interrupt must not throw
// away.
bool job_produced(const Job& j) {
  return j.status == TC_OK || j.out_h != 0 || (j.op == Op::ConnRead && j.count > 0);
}

// handle_x is null for jobs that do not operate on a handle. lane is LANE_READ
// or LANE_WRITE for connection I/O and -1 otherwise.
cpp11::sexp submit(const std::shared_ptr<Job>& j, const cpp11::sexp* handle_x,
                   Handle* hp, double timeout, const cpp11::sexp& callback,
                   const char* arg_problem = nullptr, int lane = -1) {
  std::unique_ptr<AsyncCall> call;
  if (arg_callback(callback)) {
    j->loop_id = current_loop_id();
    call.reset(new AsyncCall(j, handle_x != nullptr ? *handle_x : cpp11::sexp(),
                             cpp11::function(callback)));
  }

  if (handle_x != nullptr && hp == nullptr) {
    return finish_early(*j, call, TC_CLOSED, "");
  }
  if (arg_problem != nullptr) {
    return finish_early(*j, call, TC_INVALID_ARGUMENT, arg_problem);
  }
  int64_t ns = 0;
  if (!timeout_to_ns(timeout, &ns)) {
    return finish_early(*j, call, TC_INVALID_ARGUMENT,
                        "rtailcat: timeout must be a non-negative number of seconds or Inf");
  }

  std::string limit_problem;
  if (!within_operation_limit(&limit_problem)) {
    return finish_early(*j, call, TC_FAILURE, limit_problem);
  }

  if (hp != nullptr) {
    j->handle = hp;
    j->h = hp->h;
  }

  j->probe = timeout == 0 && j->op == Op::ConnRead && j->n > 0 && hp != nullptr &&
             hp->network == network_tcp;
  char* err = nullptr;
  int32_t st = tc_token_new(j->probe ? -1 : ns, &j->token, &err);
  if (st != TC_OK) {
    std::string msg;
    take_string(err, msg);
    return finish_early(*j, call, st, msg);
  }
  // Beyond about three years the deadline is treated as none, which also keeps
  // the time_point arithmetic from overflowing.
  if (ns >= 0 && ns < INT64_C(100000000000000000)) {
    j->has_deadline = true;
    j->deadline = steady::now() + std::chrono::nanoseconds(ns);
  }

  cpp11::sexp cancel;
  if (call) {
    try {
      cancel = make_cancel(j->token, j);
    } catch (...) {
      tc_close(j->token, nullptr);
      throw;
    }
  }

  // Joining the lane here, on the main thread, is what fixes the order.
  if (lane >= 0) {
    j->lane = hp->lanes[lane];
    std::lock_guard<std::mutex> lock(j->lane->m);
    j->lane->jobs.push_back(j.get());
    j->queued = true;
  }

  operations_in_flight.fetch_add(1);
  try {
    std::thread(worker_main, j, call.get()).detach();
  } catch (const std::system_error&) {
    operations_in_flight.fetch_sub(1);
    if (j->lane) {
      leave_lane(*j);
      j->lane.reset();
    }
    tc_close(j->token, nullptr);
    return finish_early(*j, call, TC_FAILURE, "rtailcat: could not start a worker thread");
  }

  if (call) {
    post_complete(call.release());
    return cancel;
  }

  try {
    for (;;) {
      {
        std::unique_lock<std::mutex> lock(j->m);
        if (j->cv.wait_for(lock, std::chrono::milliseconds(50),
                           [&] { return j->done; })) {
          break;
        }
      }
      cpp11::check_user_interrupt();
    }
  } catch (...) {
    // The ABI requires buffers and outputs to outlive the original call, so
    // wait for the worker before deciding what to do with the interrupt.
    request_cancel(*j);
    {
      std::unique_lock<std::mutex> lock(j->m);
      j->cv.wait(lock, [&] { return j->done; });
    }
    // A job that completed despite the interrupt (it finished at the same
    // moment) returns its result, because the interrupt cannot be raised
    // again after this frame returns and the data would otherwise be lost.
    if (!job_produced(*j)) {
      throw;
    }
  }

  return take_result(*j);
}

const char* check_port(int port, uint16_t* out) {
  // NA_integer_ arrives as INT_MIN and is rejected here too.
  if (port < 0 || port > 65535) {
    return "rtailcat: port must be an integer between 0 and 65535";
  }
  *out = static_cast<uint16_t>(port);
  return nullptr;
}

int32_t network_code(int network) { return network == INT_MIN ? 0 : network; }

cpp11::sexp nonblocking_string(int32_t status, char* out, char* err) {
  std::string value;
  std::string message;
  take_string(out, value);
  take_string(err, message);
  if (status != TC_OK) {
    return make_error(status, message, 0);
  }
  return cpp11::as_sexp(value);
}

cpp11::sexp nonblocking_handle(int32_t status, tc_handle h, char* err, int kind) {
  std::string message;
  take_string(err, message);
  if (status != TC_OK) {
    return make_error(status, message, 0);
  }
  try {
    return make_handle(h, kind);
  } catch (...) {
    close_quietly(h);
    throw;
  }
}

}  // namespace

// ---- Non-blocking entry points ---------------------------------------------

[[cpp11::register]]
int rtc_abi_version() {
  fork_guard();
  return static_cast<int>(tc_abi_version());
}

[[cpp11::register]]
cpp11::sexp rtc_build_info() {
  fork_guard();
  char* out = nullptr;
  char* err = nullptr;
  int32_t st = tc_build_info(&out, &err);
  return nonblocking_string(st, out, err);
}

[[cpp11::register]]
cpp11::sexp rtc_key_generate() {
  fork_guard();
  char* out = nullptr;
  char* err = nullptr;
  int32_t st = tc_key_generate(&out, &err);
  return nonblocking_string(st, out, err);
}

[[cpp11::register]]
cpp11::sexp rtc_address_parse(std::string address) {
  fork_guard();
  char* out = nullptr;
  char* err = nullptr;
  int32_t st = tc_address_parse(address.data(), &out, &err);
  return nonblocking_string(st, out, err);
}

[[cpp11::register]]
cpp11::sexp rtc_client_new(std::string config_json) {
  fork_guard();
  tc_handle h = 0;
  char* err = nullptr;
  int32_t st = tc_client_new(config_json.data(), &h, &err);
  return nonblocking_handle(st, h, err, KIND_CLIENT);
}

[[cpp11::register]]
cpp11::sexp rtc_server_new(std::string config_json) {
  fork_guard();
  tc_handle h = 0;
  char* err = nullptr;
  int32_t st = tc_server_new(config_json.data(), &h, &err);
  return nonblocking_handle(st, h, err, KIND_SERVER);
}

[[cpp11::register]]
bool rtc_close(cpp11::sexp handle) {
  fork_guard();
  Handle* p = arg_handle(handle, KIND_ANY, "handle");
  if (p == nullptr || p->closed.exchange(true)) {
    return false;
  }
  tc_close(p->h, nullptr);
  wake_lanes(p);
  return true;
}

[[cpp11::register]]
bool rtc_is_closed(cpp11::sexp handle) {
  fork_guard();
  return arg_handle(handle, KIND_ANY, "handle") == nullptr;
}

// TRUE for a handle restored from a saved session: its external pointer is
// NULL because pointers do not survive serialization.
[[cpp11::register]]
bool rtc_is_restored(cpp11::sexp handle) {
  fork_guard();
  arg_handle(handle, KIND_ANY, "handle");
  return handle_ptr(handle).get() == nullptr;
}

// Signals cancellation of an async job. Returns TRUE if the job was still
// waiting for its turn or its token was still open (it was running, or had
// just finished and not yet released the token), FALSE otherwise, including
// for a job that never started.
[[cpp11::register]]
bool rtc_cancel(cpp11::sexp cancel) {
  fork_guard();
  Cancel* p = nullptr;
  try {
    p = cancel_ptr(cancel).get();
  } catch (const cpp11::type_error&) {
    cpp11::stop("`cancel` must be an rtailcat cancel handle");
  }
  if (p == nullptr) {
    if (!base_predicate("inherits", cancel, "rtc_cancel")) {
      cpp11::stop("`cancel` must be an rtailcat cancel handle");
    }
    return false;
  }
  if (live_cancels().count(p) == 0) {
    cpp11::stop("`cancel` must be an rtailcat cancel handle");
  }
  if (std::shared_ptr<Job> j = p->job.lock()) {
    return request_cancel(*j);
  }
  if (p->token == 0) {
    return false;
  }
  return tc_token_cancel(p->token, nullptr) == TC_OK;
}

[[cpp11::register]]
cpp11::sexp rtc_conn_readable(cpp11::sexp conn) {
  fork_guard();
  Handle* p = arg_handle(conn, KIND_CONNECTION, "conn");
  if (p == nullptr) {
    return make_error(TC_CLOSED, "", 0);
  }
  int32_t ready = 0;
  char* err = nullptr;
  int32_t st = tc_conn_readable(p->h, &ready, &err);
  std::string message;
  take_string(err, message);
  if (st != TC_OK) {
    return make_error(st, message, 0);
  }
  return cpp11::as_sexp(ready != 0);
}

// TRUE once close_write has succeeded on the connection; FALSE for a closed
// connection.
[[cpp11::register]]
bool rtc_conn_write_shut(cpp11::sexp conn) {
  fork_guard();
  Handle* p = arg_handle(conn, KIND_CONNECTION, "conn");
  return p != nullptr && p->write_shut.load();
}

// For tests: the number of operations holding a worker thread.
[[cpp11::register]]
double rtc_operations_in_flight() {
  return static_cast<double>(operations_in_flight.load());
}

// ---- Blocking entry points -------------------------------------------------

[[cpp11::register]]
cpp11::sexp rtc_server_start(cpp11::sexp server, double timeout, cpp11::sexp callback) {
  fork_guard();
  Handle* p = arg_handle(server, KIND_SERVER, "server");
  auto j = std::make_shared<Job>(Op::ServerStart);
  return submit(j, &server, p, timeout, callback);
}

[[cpp11::register]]
cpp11::sexp rtc_server_listen(cpp11::sexp server, int port, int network, double timeout,
                              cpp11::sexp callback) {
  fork_guard();
  Handle* p = arg_handle(server, KIND_SERVER, "server");
  auto j = std::make_shared<Job>(Op::ServerListen);
  const char* problem = check_port(port, &j->port);
  j->network = network_code(network);
  return submit(j, &server, p, timeout, callback, problem);
}

[[cpp11::register]]
cpp11::sexp rtc_listener_accept(cpp11::sexp listener, double timeout,
                                cpp11::sexp callback) {
  fork_guard();
  Handle* p = arg_handle(listener, KIND_LISTENER, "listener");
  auto j = std::make_shared<Job>(Op::ListenerAccept);
  if (p != nullptr) {
    j->network = p->network;
  }
  return submit(j, &listener, p, timeout, callback);
}

[[cpp11::register]]
cpp11::sexp rtc_client_dial(cpp11::sexp client, int port, int network, double timeout,
                            cpp11::sexp callback) {
  fork_guard();
  Handle* p = arg_handle(client, KIND_CLIENT, "client");
  auto j = std::make_shared<Job>(Op::ClientDial);
  const char* problem = check_port(port, &j->port);
  j->network = network_code(network);
  return submit(j, &client, p, timeout, callback, problem);
}

[[cpp11::register]]
cpp11::sexp rtc_conn_read(cpp11::sexp conn, double n, double timeout,
                          cpp11::sexp callback) {
  fork_guard();
  Handle* p = arg_handle(conn, KIND_CONNECTION, "conn");
  auto j = std::make_shared<Job>(Op::ConnRead);
  const char* problem = nullptr;
  if (std::isnan(n) || n < 0 || n > INT_MAX) {
    problem = "rtailcat: n must be a non-negative number of bytes";
  } else {
    j->n = std::min(static_cast<size_t>(n), max_read_size);
  }
  return submit(j, &conn, p, timeout, callback, problem, LANE_READ);
}

[[cpp11::register]]
cpp11::sexp rtc_conn_write(cpp11::sexp conn, cpp11::raws data, double timeout,
                           cpp11::sexp callback) {
  fork_guard();
  Handle* p = arg_handle(conn, KIND_CONNECTION, "conn");
  auto j = std::make_shared<Job>(Op::ConnWrite);
  if (p != nullptr) {
    j->buf.assign(data.begin(), data.end());
  }
  return submit(j, &conn, p, timeout, callback, nullptr, LANE_WRITE);
}

[[cpp11::register]]
cpp11::sexp rtc_conn_close_write(cpp11::sexp conn, double timeout, cpp11::sexp callback) {
  fork_guard();
  Handle* p = arg_handle(conn, KIND_CONNECTION, "conn");
  auto j = std::make_shared<Job>(Op::ConnCloseWrite);
  return submit(j, &conn, p, timeout, callback, nullptr, LANE_WRITE);
}

[[cpp11::register]]
cpp11::sexp rtc_info(cpp11::sexp handle, double timeout, cpp11::sexp callback) {
  fork_guard();
  Handle* p = arg_handle(handle, KIND_ANY, "handle");
  auto j = std::make_shared<Job>(Op::Info);
  return submit(j, &handle, p, timeout, callback);
}

[[cpp11::register]]
cpp11::sexp rtc_client_ping(cpp11::sexp client, double timeout, cpp11::sexp callback) {
  fork_guard();
  Handle* p = arg_handle(client, KIND_CLIENT, "client");
  auto j = std::make_shared<Job>(Op::ClientPing);
  return submit(j, &client, p, timeout, callback);
}

[[cpp11::register]]
cpp11::sexp rtc_client_disco_ping(cpp11::sexp client, double timeout,
                                  cpp11::sexp callback) {
  fork_guard();
  Handle* p = arg_handle(client, KIND_CLIENT, "client");
  auto j = std::make_shared<Job>(Op::ClientDiscoPing);
  return submit(j, &client, p, timeout, callback);
}

[[cpp11::register]]
cpp11::sexp rtc_server_allow_client(cpp11::sexp server, std::string public_key,
                                    double timeout, cpp11::sexp callback) {
  fork_guard();
  Handle* p = arg_handle(server, KIND_SERVER, "server");
  auto j = std::make_shared<Job>(Op::ServerAllowClient);
  j->s1 = std::move(public_key);
  return submit(j, &server, p, timeout, callback);
}

[[cpp11::register]]
cpp11::sexp rtc_drain(cpp11::sexp handle, double timeout, cpp11::sexp callback) {
  fork_guard();
  Handle* p = arg_handle(handle, KIND_CLIENT | KIND_SERVER, "handle");
  auto j = std::make_shared<Job>(Op::Drain);
  return submit(j, &handle, p, timeout, callback);
}

[[cpp11::register]]
cpp11::sexp rtc_address_resolve(std::string address, cpp11::sexp derp_map_url,
                                double timeout, cpp11::sexp callback) {
  fork_guard();
  auto j = std::make_shared<Job>(Op::AddressResolve);
  j->s1 = std::move(address);
  if (!base_predicate("is.null", derp_map_url)) {
    j->s2 = cpp11::as_cpp<std::string>(derp_map_url);
  }
  return submit(j, nullptr, nullptr, timeout, callback);
}
