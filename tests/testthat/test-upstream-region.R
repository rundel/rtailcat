test_that("a custom region keeps the relay fields tailcat uses and drops the rest in the address", {
  # from wire_test.go: TestWireRegionRoundTrip; tailcat_test.go: TestAddr (remove_implicit_fields_on_marshal)
  skip_relay()
  # Built with rtailcat's snake_case field names, which TailcatServer$new()
  # translates; the local relay's region arrives in tailcat's PascalCase.
  region = relay_region()
  region = if (is.null(region)) {
    probe = local_server()
    probe$start()
    on.exit(probe$close())
    tailcat_address_parse(probe$address)$regions[[1]]
  } else {
    rtailcat:::tailcat_fields(region)
  }
  node = region$nodes[[1]]
  region$region_id = 123L
  region$region_code = "custom"
  region$region_name = "Custom Region"
  region$latitude = 47.6
  region$longitude = -122.3
  region$avoid = TRUE
  region$nodes = list(
    utils::modifyList(node, list(region_id = 123L, can_port_80 = TRUE)),
    list(name = "stun-only", region_id = 123L, host_name = "stun-only.invalid", stun_only = TRUE)
  )

  srv = local_server(region = region)
  srv$start(timeout = 30)
  got = tailcat_address_parse(srv$address)$regions
  expect_length(got, 1)
  got = got[[1]]
  expect_identical(got$region_id, 1L)
  expect_identical(got$region_code, "1")
  expect_false(any(c("latitude", "longitude", "avoid") %in% names(got)))
  expect_identical(got$region_name %||% "", "")
  expect_length(got$nodes, 1)
  kept = got$nodes[[1]]
  expect_identical(kept$host_name, node$host_name)
  expect_identical(kept$name, node$host_name)
  expect_false("can_port_80" %in% names(kept))
  for (field in intersect(c("ipv4", "ipv6", "relay_port", "stun_port", "insecure_for_tests"), names(node))) {
    expect_identical(kept[[field]], node[[field]])
  }
})

test_that("TailcatServer$new() accepts a region given as a JSON string", {
  # from internal/capi/e2e_test.go: newE2E (region passed as DERPRegion JSON)
  json = '{"RegionID":1,"RegionCode":"test","Nodes":[{"Name":"n","RegionID":1,"HostName":"localhost"}]}'
  srv = TailcatServer$new(region = json)
  on.exit(srv$close())
  expect_false(srv$is_closed)
  snake = TailcatServer$new(region = '{"region_id":1,"region_code":"test","nodes":[{"name":"n","region_id":1,"host_name":"localhost","relay_port":443}]}')
  on.exit(snake$close(), add = TRUE)
  expect_false(snake$is_closed)
})

test_that("region field names are translated both ways, with explicit names for acronyms", {
  upstream = list(
    RegionID = 1L, RegionCode = "x", RegionName = "X", NoMeasureNoHome = TRUE,
    Nodes = list(list(Name = "n", RegionID = 1L, HostName = "h", CertName = "c", IPv4 = "1.2.3.4", IPv6 = "::1", STUNPort = 3478L, STUNOnly = FALSE, STUNTestIP = "1.2.3.5", DERPPort = 443L, CanPort80 = TRUE, InsecureForTests = TRUE))
  )
  snake = rtailcat:::tailcat_fields(upstream)
  expect_named(snake, c("region_id", "region_code", "region_name", "no_measure_no_home", "nodes"))
  expect_named(snake$nodes[[1]], c("name", "region_id", "host_name", "cert_name", "ipv4", "ipv6", "stun_port", "stun_only", "stun_test_ip", "relay_port", "can_port_80", "insecure_for_tests"))
  expect_identical(rtailcat:::upstream_fields(snake), upstream)
  expect_identical(rtailcat:::upstream_fields(upstream), upstream)
  expect_identical(rtailcat:::tailcat_fields(list(SomeNewField = 1, derp_region_id = 2)), list(some_new_field = 1, relay_region_id = 2))
  expect_identical(rtailcat:::upstream_fields(list(some_new_field = 1)), list(SomeNewField = 1))
  expect_error(TailcatServer$new(region = list(region_id = 1L, bogus_field = 1)), "region", class = "tailcat_invalid_argument")
})
