import brownie

from brownie import Wei


def test_multiple_withdrawals(token, gov, vault, TestStrategy):
    strategies = [gov.deploy(TestStrategy, vault) for _ in range(5)]
    [vault.addStrategy(s, 1000, 10, 50, {"from": gov}) for s in strategies]

    before_balance = token.balanceOf(gov)

    token.approve(vault, 2 ** 256 - 1, {"from": gov})
    vault.deposit(token.balanceOf(gov), {"from": gov})

    assert token.balanceOf(gov) < before_balance
    before_balance = token.balanceOf(gov)

    [s.harvest({"from": gov}) for s in strategies]  # Seed all the strategies with debt

    for s in strategies:  # All of them have debt
        print(s, vault.balanceSheetOfStrategy(s))
        assert vault.balanceSheetOfStrategy(s) > 0
        assert vault.balanceSheetOfStrategy(s) == token.balanceOf(s)

    # We withdraw from all the strategies
    vault.withdraw(vault.balanceOf(gov) // 2, {"from": gov})
    assert token.balanceOf(gov) > before_balance
    before_balance = token.balanceOf(gov)

    assert vault.balanceOf(gov) > 0
    vault.withdraw(vault.balanceOf(gov), {"from": gov})
    assert token.balanceOf(gov) > before_balance

    for s in strategies:  # Should have pulled everything from each strategy
        assert vault.balanceSheetOfStrategy(s) == 0


def test_malicius_user_withdrawal(token, gov, vault, TestStrategy, rando):
    # Add strategies
    strategies = [gov.deploy(TestStrategy, vault) for _ in range(5)]
    [vault.addStrategy(s, 1000, 10, 50, {"from": gov}) for s in strategies]

    # Send tokens to the rando user
    token.approve(gov, 2 ** 256 - 1, {"from": gov})
    token.transferFrom(gov, rando, Wei("100 ether"), {"from": gov})
    assert token.balanceOf(rando) == Wei("100 ether")

    # rando and gov deposits tokens to the vault
    token.approve(vault, 2 ** 256 - 1, {"from": gov})
    token.approve(vault, 2 ** 256 - 1, {"from": rando})

    # TODO: Vault v2 doesn't have depositAll()? why?
    vault.deposit(token.balanceOf(rando), {"from": rando})
    vault.deposit(Wei("10 ether"), {"from": gov})

    assert token.balanceOf(rando) == 0
    assert vault.balanceOf(rando) > 0
    assert vault.balanceOf(gov) > 0

    # invest tokens into strategies
    [s.harvest({"from": gov}) for s in strategies]

    # User shouldn't be able to withdraw more than what they have
    with brownie.reverts():
        vault.withdraw(Wei("110 ether"), {"from": rando})
