# usdc-reserve

reserve contract on initia l1 that backs the existing USDC.n token with USDC.inj. using for the noble to injective USDC migration.

- `issue` mints into the vault and the minted USDC.n only leaves through `wrap`, 1:1 against USDC.inj, so it never circulates unbacked
- the funder pays with `wrap` after the vote, so nothing needs refunding if the vote fails. anyone can fund and the vault ends up the same whoever does
- `legacy_balance + backing_balance >= total_issued` in `get_reserve_info`, equal unless someone transfers tokens straight to the vault address
- the vault is an object owned by `@0x0` so no key can withdraw from it directly, funds only move through the contract (or a gov proposal acting as the vault address)
- `issue` is gov only (sudo_mint needs the 0x1 signer). `set_redeemable` is gov or the publisher, so the publisher can enable or disable `redeem` but can't mint
- the package is `COMPATIBLE`, so the publisher (and gov) can upgrade it, including how vault funds move

## steps

| Step | Who | Call | Effect |
|---|---|---|---|
| 1 | x/gov | `issue(amount)` | mints `amount` of USDC.n into the vault |
| 2 | funder | `wrap(amount)` | pays `amount` of USDC.inj into the vault and takes the minted USDC.n |
| 3 | x/gov or publisher | `set_redeemable(true)` | enables `redeem`, only once noble inflow is blocked |
| 4 | user | `redeem(amount)` | USDC.n in, USDC.inj out, limited to what the vault holds |
| 4 | user | `wrap(amount)` | USDC.inj in, USDC.n out, limited to what the vault holds |

## build and test

```sh
initiad move test --dev
```

## deploy (interwoven-1)

publish with `--upgrade-policy COMPATIBLE` and

```
usdc_reserve = <multisig>
legacy_usdc  = 0xe0e9394b24e53775d6af87934ac02d73536ad58b7894f6ccff3f5e7c0d548e55
backing_usdc = 0xed4aede44bd700d6d6143a203b2e92e0875eb6949999927cb4445dadfb9502a6
```
