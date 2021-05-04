// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";

import {VaultAPI} from "./BaseStrategy.sol";

interface RegistryAPI {
    function governance() external view returns (address);

    function latestVault(address token) external view returns (address);

    function numVaults(address token) external view returns (uint256);

    function vaults(address token, uint256 deploymentId) external view returns (address);
}

/**
 * @title Yearn Base Wrapper
 * @author yearn.finance
 * @notice
 *  BaseWrapper implements all of the required functionality to interoperate
 *  closely with the Vault contract. This contract should be inherited and the
 *  abstract methods implemented to adapt the Wrapper.
 *  A good starting point to build a wrapper is https://github.com/yearn/brownie-wrapper-mix
 *
 */
abstract contract BaseWrapper {
    using Math for uint256;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public token;

    // Reduce number of external calls (SLOADs stay the same)
    VaultAPI[] private _cachedVaults;

    RegistryAPI public registry;

    // ERC20 Unlimited Approvals (short-circuits VaultAPI.transferFrom)
    uint256 constant UNLIMITED_APPROVAL = type(uint256).max;
    // Sentinal values used to save gas on deposit/withdraw/migrate
    // NOTE: DEPOSIT_EVERYTHING == WITHDRAW_EVERYTHING == MIGRATE_EVERYTHING
    uint256 constant DEPOSIT_EVERYTHING = type(uint256).max;
    uint256 constant WITHDRAW_EVERYTHING = type(uint256).max;
    uint256 constant MIGRATE_EVERYTHING = type(uint256).max;
    // VaultsAPI.depositLimit is unlimited
    uint256 constant UNCAPPED_DEPOSITS = type(uint256).max;

    constructor(address _token, address _registry) public {
        // Recommended to use a token with a `Registry.latestVault(_token) != address(0)`
        token = IERC20(_token);
        // Recommended to use `v2.registry.ychad.eth`
        registry = RegistryAPI(_registry);
    }

    /**
     * @notice
     *  Used to update the yearn registry.
     * @param _registry The new _registry address.
     */
    function setRegistry(address _registry) external {
        require(msg.sender == registry.governance());
        // In case you want to override the registry instead of re-deploying
        registry = RegistryAPI(_registry);
        // Make sure there's no change in governance
        // NOTE: Also avoid bricking the wrapper from setting a bad registry
        require(msg.sender == registry.governance());
    }

    /**
     * @notice
     *  Used to get the most revent vault for the token using the registry.
     * @return An instance of a VaultAPI
     */
    function bestVault() public virtual view returns (VaultAPI) {
        return VaultAPI(registry.latestVault(address(token)));
    }

    /**
     * @notice
     *  Used to get all vaults from the registery for the token
     * @return An array containing instances of VaultAPI
     */
    function allVaults() public virtual view returns (VaultAPI[] memory) {
        uint256 cache_length = _cachedVaults.length;
        uint256 num_vaults = registry.numVaults(address(token));

        // Use cached
        if (cache_length == num_vaults) {
            return _cachedVaults;
        }

        VaultAPI[] memory vaults = new VaultAPI[](num_vaults);

        for (uint256 vault_id = 0; vault_id < cache_length; vault_id++) {
            vaults[vault_id] = _cachedVaults[vault_id];
        }

        for (uint256 vault_id = cache_length; vault_id < num_vaults; vault_id++) {
            vaults[vault_id] = VaultAPI(registry.vaults(address(token), vault_id));
        }

        return vaults;
    }

    function _updateVaultCache(VaultAPI[] memory vaults) internal {
        // NOTE: even though `registry` is update-able by Yearn, the intended behavior
        //       is that any future upgrades to the registry will replay the version
        //       history so that this cached value does not get out of date.
        if (vaults.length > _cachedVaults.length) {
            _cachedVaults = vaults;
        }
    }

    /**
     * @notice
     *  Used to get the balance of an account accross all the vaults for a token.
     *  @dev will be used to get the wrapper balance using totalVaultBalance(address(this)).
     *  @param account The address of the account.
     *  @return balance of token for the account accross all the vaults.
     */
    function totalVaultBalance(address account) public view returns (uint256 balance) {
        VaultAPI[] memory vaults = allVaults();

        for (uint256 id = 0; id < vaults.length; id++) {
            balance = balance.add(vaults[id].balanceOf(account).mul(vaults[id].pricePerShare()).div(10**uint256(vaults[id].decimals())));
        }
    }

    /**
     * @notice
     *  Used to get the TVL on the underlying vaults.
     *  @return assets the sum of all the assets managed by the underlying vaults.
     */
    function totalAssets() public view returns (uint256 assets) {
        VaultAPI[] memory vaults = allVaults();

        for (uint256 id = 0; id < vaults.length; id++) {
            assets = assets.add(vaults[id].totalAssets());
        }
    }

    function _deposit(
        address depositor,
        address receiver,
        uint256 amount, // if `MAX_UINT256`, just deposit everything
        bool pullFunds // If true, funds need to be pulled from `depositor` via `transferFrom`
    ) internal returns (uint256 deposited) {
        VaultAPI _bestVault = bestVault();

        if (pullFunds) {
            if (amount != DEPOSIT_EVERYTHING) {
                token.safeTransferFrom(depositor, address(this), amount);
            } else {
                token.safeTransferFrom(depositor, address(this), token.balanceOf(depositor));
            }
        }

        if (token.allowance(address(this), address(_bestVault)) < amount) {
            token.safeApprove(address(_bestVault), 0); // Avoid issues with some tokens requiring 0
            token.safeApprove(address(_bestVault), UNLIMITED_APPROVAL); // Vaults are trusted
        }

        // Depositing returns number of shares deposited
        // NOTE: Shortcut here is assuming the number of tokens deposited is equal to the
        //       number of shares credited, which helps avoid an occasional multiplication
        //       overflow if trying to adjust the number of shares by the share price.
        uint256 beforeBal = token.balanceOf(address(this));
        if (receiver != address(this)) {
            _bestVault.deposit(amount, receiver);
        } else if (amount != DEPOSIT_EVERYTHING) {
            _bestVault.deposit(amount);
        } else {
            _bestVault.deposit();
        }

        uint256 afterBal = token.balanceOf(address(this));
        deposited = beforeBal.sub(afterBal);
        // `receiver` now has shares of `_bestVault` as balance, converted to `token` here
        // Issue a refund if not everything was deposited
        if (depositor != address(this) && afterBal > 0) token.safeTransfer(depositor, afterBal);
    }

    function _withdraw(
        address sender,
        address receiver,
        uint256 amount, // if `MAX_UINT256`, just withdraw everything
        bool withdrawFromBest // If true, also withdraw from `_bestVault`
    ) internal returns (uint256 withdrawn) {
        VaultAPI _bestVault = bestVault();

        VaultAPI[] memory vaults = allVaults();
        _updateVaultCache(vaults);

        // NOTE: This loop will attempt to withdraw from each Vault in `allVaults` that `sender`
        //       is deposited in, up to `amount` tokens. The withdraw action can be expensive,
        //       so it if there is a denial of service issue in withdrawing, the downstream usage
        //       of this wrapper contract must give an alternative method of withdrawing using
        //       this function so that `amount` is less than the full amount requested to withdraw
        //       (e.g. "piece-wise withdrawals"), leading to less loop iterations such that the
        //       DoS issue is mitigated (at a tradeoff of requiring more txns from the end user).
        for (uint256 id = 0; id < vaults.length; id++) {
            if (!withdrawFromBest && vaults[id] == _bestVault) {
                continue; // Don't withdraw from the best
            }

            // Start with the total shares that `sender` has
            uint256 availableShares = vaults[id].balanceOf(sender);

            // Restrict by the allowance that `sender` has to this contract
            // NOTE: No need for allowance check if `sender` is this contract
            if (sender != address(this)) {
                availableShares = Math.min(availableShares, vaults[id].allowance(sender, address(this)));
            }

            // Limit by maximum withdrawal size from each vault
            availableShares = Math.min(availableShares, vaults[id].maxAvailableShares());

            if (availableShares > 0) {
                // Intermediate step to move shares to this contract before withdrawing
                // NOTE: No need for share transfer if this contract is `sender`
                if (sender != address(this)) vaults[id].transferFrom(sender, address(this), availableShares);

                if (amount != WITHDRAW_EVERYTHING) {
                    // Compute amount to withdraw fully to satisfy the request
                    uint256 estimatedShares = amount
                        .sub(withdrawn) // NOTE: Changes every iteration
                        .mul(10**uint256(vaults[id].decimals()))
                        .div(vaults[id].pricePerShare()); // NOTE: Every Vault is different

                    // Limit amount to withdraw to the maximum made available to this contract
                    // NOTE: Avoid corner case where `estimatedShares` isn't precise enough
                    // NOTE: If `0 < estimatedShares < 1` but `availableShares > 1`, this will withdraw more than necessary
                    if (estimatedShares > 0 && estimatedShares < availableShares) {
                        withdrawn = withdrawn.add(vaults[id].withdraw(estimatedShares));
                    } else {
                        withdrawn = withdrawn.add(vaults[id].withdraw(availableShares));
                    }
                } else {
                    withdrawn = withdrawn.add(vaults[id].withdraw());
                }

                // Check if we have fully satisfied the request
                // NOTE: use `amount = WITHDRAW_EVERYTHING` for withdrawing everything
                if (amount <= withdrawn) break; // withdrawn as much as we needed
            }
        }

        // If we have extra, deposit back into `_bestVault` for `sender`
        // NOTE: Invariant is `withdrawn <= amount`
        if (withdrawn > amount && amount > _bestVault.pricePerShare().div(10**_bestVault.decimals())) {
            // Don't forget to approve the deposit
            if (token.allowance(address(this), address(_bestVault)) < withdrawn.sub(amount)) {
                token.safeApprove(address(_bestVault), UNLIMITED_APPROVAL); // Vaults are trusted
            }

            _bestVault.deposit(withdrawn.sub(amount), sender);
            withdrawn = amount;
        }

        // `receiver` now has `withdrawn` tokens as balance
        if (receiver != address(this)) token.safeTransfer(receiver, withdrawn);
    }

    function _migrate(address account) internal returns (uint256) {
        return _migrate(account, MIGRATE_EVERYTHING);
    }

    function _migrate(address account, uint256 amount) internal returns (uint256) {
        // NOTE: In practice, it was discovered that <50 was the maximum we've see for this variance
        return _migrate(account, amount, 0);
    }

    function _migrate(
        address account,
        uint256 amount,
        uint256 maxMigrationLoss
    ) internal returns (uint256 migrated) {
        VaultAPI _bestVault = bestVault();

        // NOTE: Only override if we aren't migrating everything
        uint256 _depositLimit = _bestVault.depositLimit();
        uint256 _totalAssets = _bestVault.totalAssets();
        if (_depositLimit <= _totalAssets) return 0; // Nothing to migrate (not a failure)

        uint256 _amount = amount;
        if (_depositLimit < UNCAPPED_DEPOSITS && _amount < WITHDRAW_EVERYTHING) {
            // Can only deposit up to this amount
            uint256 _depositLeft = _depositLimit.sub(_totalAssets);
            if (_amount > _depositLeft) _amount = _depositLeft;
        }

        if (_amount > 0) {
            // NOTE: `false` = don't withdraw from `_bestVault`
            uint256 withdrawn = _withdraw(account, address(this), _amount, false);
            if (withdrawn == 0) return 0; // Nothing to migrate (not a failure)

            // NOTE: `false` = don't do `transferFrom` because it's already local
            migrated = _deposit(address(this), account, withdrawn, false);
            // NOTE: Due to the precision loss of certain calculations, there is a small inefficency
            //       on how migrations are calculated, and this could lead to a DoS issue. Hence, this
            //       value is made to be configurable to allow the user to specify how much is acceptable
            require(withdrawn.sub(migrated) <= maxMigrationLoss);
        } // else: nothing to migrate! (not a failure)
    }
}
