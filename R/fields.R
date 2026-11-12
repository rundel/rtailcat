# Field names: tailcat's JSON uses Go's PascalCase for relay regions and nodes
# (Tailscale's DERPRegion and DERPNode) and a few relay names of its own; R
# users get snake_case. Mechanical conversion handles anything not listed.
field_map = c(
  RegionID = "region_id",
  RegionCode = "region_code",
  RegionName = "region_name",
  Latitude = "latitude",
  Longitude = "longitude",
  Avoid = "avoid",
  NoMeasureNoHome = "no_measure_no_home",
  Nodes = "nodes",
  Name = "name",
  HostName = "host_name",
  CertName = "cert_name",
  IPv4 = "ipv4",
  IPv6 = "ipv6",
  STUNPort = "stun_port",
  STUNOnly = "stun_only",
  STUNTestIP = "stun_test_ip",
  DERPPort = "relay_port",
  CanPort80 = "can_port_80",
  InsecureForTests = "insecure_for_tests",
  derp_region_id = "relay_region_id",
  derp_region_code = "relay_region_code"
)

snake_case = function(x) {
  mapped = unname(field_map[x])
  mechanical = tolower(gsub("([a-z0-9])([A-Z])", "\\1_\\2", gsub("([A-Z]+)([A-Z][a-z])", "\\1_\\2", x)))
  ifelse(is.na(mapped), mechanical, mapped)
}

pascal_case = function(x) {
  mapped = names(field_map)[match(x, field_map)]
  is_snake = grepl("^[a-z][a-z0-9_]*$", x)
  mechanical = vapply(strsplit(x, "_", fixed = TRUE), function(parts) {
    paste0(toupper(substring(parts, 1, 1)), substring(parts, 2), collapse = "")
  }, "")
  ifelse(!is.na(mapped), mapped, ifelse(is_snake, mechanical, x))
}

rename_fields = function(x, rename) {
  if (!is.list(x)) {
    return(x)
  }
  out = lapply(x, rename_fields, rename = rename)
  if (!is.null(names(out))) {
    names(out) = rename(names(out))
  }
  out
}

# Applied to everything parsed from tailcat's JSON.
tailcat_fields = function(x) {
  rename_fields(x, snake_case)
}

# For a relay region passed in by the user, in either style.
upstream_fields = function(x) {
  rename_fields(x, pascal_case)
}
