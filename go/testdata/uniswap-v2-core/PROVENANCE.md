# Provenance

Artifacts of `@uniswap/v2-core` 1.0.1 (git tag `v1.0.1`, commit `4dd59067c76dea4a0e8e4bfdda41877a6b16dedc`), copied unchanged from the npm package `build/` directory: `UniswapV2Pair.json`, `UniswapV2Factory.json`, `ERC20.json` (the test token of v2-core, `contracts/test/ERC20.sol`). `LICENSE` is the package's GPL-3.0 text.

- Tarball: https://registry.npmjs.org/@uniswap/v2-core/-/v2-core-1.0.1.tgz
- Integrity (sha512, base64): `MtybtkUPSyysqLY2U210NBDeCHX+ltHt3oADGdjqoThZaFRDKwM6k1Nb3F0A3hk5hwuQvytFWhrWHOEq6nVJ8Q==`
- Compiler: solc 0.5.16, optimizer on (999999 runs), per the metadata inside each artifact.

The tests pin the sha256 of each file and the keccak256 of the pair's creation code (the init code hash of `UniswapV2Library`).

To extract again, in an empty temporary directory:

    curl -sSf https://registry.npmjs.org/@uniswap/v2-core/1.0.1 | jq -r '.gitHead, (.dist.integrity | ltrimstr("sha512-"))'   # commit and integrity above
    curl -sSfLO https://registry.npmjs.org/@uniswap/v2-core/-/v2-core-1.0.1.tgz
    openssl dgst -sha512 -binary v2-core-1.0.1.tgz | openssl base64 -A; echo   # must print the same integrity
    tar xzf v2-core-1.0.1.tgz
    cp package/build/{UniswapV2Pair,UniswapV2Factory,ERC20}.json package/LICENSE <this directory>

then `make diff`.
