# The tailcat commit the package is built against. tools/update-tailcat.sh
# rewrites this line when it moves the pin in src/go/go.mod.
tailcat_commit = "e00cdde6ff787f801361ff85ed085775c775d4c5"

tailcat_header_url = paste0("https://github.com/tailscale/tailcat/blob/", tailcat_commit, "/cmd/libtailcat/tailcat.h")

# For roxygen: every place the docs point at the C ABI header uses this link.
tailcat_header_link = function(text = "tailcat.h") {
  paste0("[", text, "](", tailcat_header_url, ")")
}
