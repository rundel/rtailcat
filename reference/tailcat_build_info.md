# Build information for the embedded tailcat library

Build information for the embedded tailcat library

## Usage

``` r
tailcat_build_info()
```

## Value

A list of class `tailcat_build_info` with elements `abi_version` (the C
ABI version, an integer), `go_version`, `tailcat_version`, and `raw`,
the full Go build metadata exactly as Go reports it (with Go's own field
names, such as `GoVersion`, `Main`, `Deps`, and `Settings`). Printing it
shows the three versions and only summarizes `raw`.

## Examples

``` r
tailcat_build_info()
#> <tailcat_build_info>
#>   tailcat_version: v0.8.0
#>   go_version:      go1.27.4
#>   abi_version:     1
#>   raw:             Go's build metadata, with 32 bundled modules
```
