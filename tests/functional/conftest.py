import pytest

from brownie import Token, TokenNoReturn


@pytest.fixture
def gov(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture(params=[("Normal", 18), ("NoReturn", 18), ("Normal", 8), ("Normal", 2)])
def token(gov, request):
    (behaviour, decimal) = request.param

    # NOTE: Run our test suite using both compliant and non-compliant ERC20 Token
    yield gov.deploy(Token if behaviour == "Normal" else TokenNoReturn, decimal)


@pytest.fixture
def vault(gov, guardian, management, token, rewards, Vault):
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})

    # Make it so vault has some AUM to start
    token.approve(vault, token.balanceOf(gov) // 2, {"from": gov})
    vault.deposit(token.balanceOf(gov) // 2, {"from": gov})
    assert token.balanceOf(vault) == token.balanceOf(gov)
    assert vault.totalDebt() == 0  # No connected strategies yet
    yield vault


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture(params=["RegularStrategy", "ClonedStrategy"])
def strategy(gov, strategist, keeper, rewards, vault, TestStrategy, request):
    strategy = strategist.deploy(TestStrategy, vault)

    if request.param == "ClonedStrategy":
        # deploy the proxy using as logic the original strategy
        tx = strategy.clone(vault, strategist, rewards, keeper, {"from": strategist})
        # strategy proxy address is returned in the event `Cloned`
        strategyAddress = tx.events["Cloned"]["clone"]
        # redefine strategy as the new proxy deployed
        strategy = TestStrategy.at(strategyAddress, owner=strategist)

    strategy.setKeeper(keeper, {"from": strategist})
    vault.addStrategy(
        strategy,
        4_000,  # 40% of Vault
        0,  # Minimum debt increase per harvest
        2 ** 256 - 1,  # maximum debt increase per harvest
        1000,  # 10% performance fee for Strategist
        {"from": gov},
    )
    yield strategy


@pytest.fixture
def rando(accounts):
    yield accounts[9]
