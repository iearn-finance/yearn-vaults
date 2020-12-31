from pathlib import Path
import yaml

import pytest
import brownie


PACKAGE_VERSION = yaml.safe_load(
    (Path(__file__).parent.parent.parent.parent / "ethpm-config.yaml").read_text()
)["version"]

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"


def test_vault_deployment(guardian, gov, rewards, token, Vault):
    # Deploy the Vault without any name/symbol overrides
    vault = guardian.deploy(Vault)
    vault.initialize(
        token, gov, rewards, token.symbol() + " yVault", "yv" + token.symbol(), guardian
    )
    # Addresses
    assert vault.governance() == gov
    assert vault.management() == gov
    assert vault.guardian() == guardian
    assert vault.rewards() == rewards
    assert vault.token() == token
    # UI Stuff
    assert vault.name() == token.symbol() + " yVault"
    assert vault.symbol() == "yv" + token.symbol()
    assert vault.decimals() == token.decimals()
    assert vault.apiVersion() == PACKAGE_VERSION

    assert vault.debtLimit() == 0
    assert vault.depositLimit() == 0
    assert vault.creditAvailable() == 0
    assert vault.debtOutstanding() == 0
    assert vault.maxAvailableShares() == 0
    assert vault.totalAssets() == 0
    assert vault.pricePerShare() / (10 ** vault.decimals()) == 1.0


def test_vault_name_symbol_override(guardian, gov, rewards, token, Vault):
    # Deploy the Vault with name/symbol overrides
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "crvY yVault", "yvcrvY", guardian)
    # Assert that the overrides worked
    assert vault.name() == "crvY yVault"
    assert vault.symbol() == "yvcrvY"


@pytest.mark.parametrize(
    "getter,setter,val,guard_allowed",
    [
        ("name", "setName", "NewName yVault", False),
        ("symbol", "setSymbol", "yvNEW", False),
        ("emergencyShutdown", "setEmergencyShutdown", True, True),
        ("guardian", "setGuardian", None, True),
        ("rewards", "setRewards", None, False),
        ("management", "setManagement", None, False),
        ("performanceFee", "setPerformanceFee", 1000, False),
        ("managementFee", "setManagementFee", 1000, False),
        ("depositLimit", "setDepositLimit", 1000, False),
    ],
)
def test_vault_setParams(
    chain, gov, guardian, management, vault, rando, getter, setter, val, guard_allowed,
):
    if not val:
        # Can't access fixtures, so use None to mean any random address
        val = rando

    # rando shouldn't be able to call these methods
    with brownie.reverts():
        getattr(vault, setter)(val, {"from": rando})

    if guard_allowed:
        getattr(vault, setter)(val, {"from": guardian})
        assert getattr(vault, getter)() == val
        chain.undo()
    else:
        with brownie.reverts():
            getattr(vault, setter)(val, {"from": guardian})

    # Management is never allowed
    with brownie.reverts():
        getattr(vault, setter)(val, {"from": management})

    # gov is always allowed
    getattr(vault, setter)(val, {"from": gov})
    assert getattr(vault, getter)() == val


@pytest.mark.parametrize(
    "key,setter,val",
    [
        ("debtLimit", "updateStrategyDebtLimit", 500),
        ("rateLimit", "updateStrategyRateLimit", 10),
    ],
)
def test_vault_updateStrategy(
    chain, gov, guardian, management, vault, strategy, rando, key, setter, val
):

    # rando shouldn't be able to call these methods
    with brownie.reverts():
        getattr(vault, setter)(strategy, val, {"from": rando})

    # guardian is never allowed
    with brownie.reverts():
        getattr(vault, setter)(strategy, val, {"from": guardian})

    # management is always allowed
    getattr(vault, setter)(strategy, val, {"from": management})
    assert vault.strategies(strategy).dict()[key] == val
    chain.undo()

    # gov is always allowed
    getattr(vault, setter)(strategy, val, {"from": gov})
    assert vault.strategies(strategy).dict()[key] == val


def test_vault_setGovernance(gov, vault, rando):
    newGov = rando
    # No one can set governance but governance
    with brownie.reverts():
        vault.setGovernance(newGov, {"from": newGov})
    # Governance doesn't change until it's accepted
    vault.setGovernance(newGov, {"from": gov})
    assert vault.governance() == gov
    # Only new governance can accept a change of governance
    with brownie.reverts():
        vault.acceptGovernance({"from": gov})
    # Governance doesn't change until it's accepted
    vault.acceptGovernance({"from": newGov})
    assert vault.governance() == newGov
    # No one can set governance but governance
    with brownie.reverts():
        vault.setGovernance(newGov, {"from": gov})
    # Only new governance can accept a change of governance
    with brownie.reverts():
        vault.acceptGovernance({"from": gov})
