# Build information for the embedded tailcat library

Build information for the embedded tailcat library

## Usage

``` r
tailcat_build_info()
```

## Value

A list with elements `abi_version` (the C ABI version, an integer),
`go_version`, `tailcat_version`, and `raw`, the full Go build metadata
exactly as Go reports it (with Go's own field names, such as
`GoVersion`, `Main`, `Deps`, and `Settings`).

## Examples

``` r
tailcat_build_info()[c("abi_version", "go_version", "tailcat_version")]
#> $abi_version
#> [1] 1
#> 
#> $go_version
#> [1] "go1.27.2"
#> 
#> $tailcat_version
#> [1] "v0.7.1-0.20261105151022-e00cdde6ff78"
#> 
```
