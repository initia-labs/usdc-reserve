# usdc-reserve

reserve contract on initia l1 that backs the existing USDC.n token with USDC.inj. using for the noble to injective USDC migration.

- `issue` is the only path into the vault accounting and it mints exactly what it commits
- vault USDC.inj + vault USDC.n = total issued after any sequence of swaps
- deposit is refundable until governance commits and any headroom above the issued amount stays withdrawable
- vaults are objects owned by `@0x0` so no key can withdraw from them, funds only move through the contract (or a gov proposal acting as the vault address)
- `issue` is gov only (sudo_mint needs the 0x1 signer). `set_redeem_open` is gov or the publisher, so the publisher can pause redeem but can't mint or move funds

## steps

| Step | Who | Call | Effect |
|---|---|---|---|
| 1 | funder | `deposit(amount)` | USDC.inj goes to the pending vault, withdrawable with `withdraw_deposit` |
| 2 | x/gov | `issue(funder, amount)` | moves `amount` of the funder deposit into the vault and mints `amount` of the existing token to the funder |
| 3 | x/gov or publisher | `set_redeem_open(true)` | opens `redeem` only once noble inflow is blocked |
| 4 | user | `redeem(amount)` | USDC.n in USDC.inj out |
| 4 | user | `wrap(amount)` | USDC.inj in existing token out limited to what the vault holds |

## build and test

```sh
initiad move test --dev
```

## deploy (interwoven-1)

publish with `--upgrade-policy IMMUTABLE` and

```
usdc_reserve = <multisig>
legacy_usdc  = 0xe0e9394b24e53775d6af87934ac02d73536ad58b7894f6ccff3f5e7c0d548e55
backing_usdc = 0xed4aede44bd700d6d6143a203b2e92e0875eb6949999927cb4445dadfb9502a6
```
