// MIT License
//
// Copyright (c) 2024 PancakeSwap
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
pragma solidity ^0.8.10;

import "@openzeppelin-4.5.0/contracts/access/Ownable.sol";
import "@openzeppelin-4.5.0/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin-4.5.0/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin-4.5.0/contracts/security/ReentrancyGuard.sol";
import "./IStableSwapLP.sol";

contract StableSwapTwoPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant N_COINS = 2;

    uint256 public constant MAX_DECIMAL = 18;
    uint256 public constant FEE_DENOMINATOR = 1e10;
    uint256 public constant PRECISION = 1e18;
    uint256[N_COINS] public PRECISION_MUL;
    uint256[N_COINS] public RATES;

    uint256 public constant MAX_ADMIN_FEE = 1e10;
    uint256 public constant MAX_FEE = 5e9;
    uint256 public constant MAX_AMPLIFICATION_COEFFICIENT = 1e6;
    uint256 public constant MAX_AMPLIFICATION_COEFFICIENT_CHANGE = 10;
    uint256 public constant MIN_NATIVE_GAS = 2300;
    uint256 public constant MAX_NATIVE_GAS = 23000;

    uint256 public constant ADMIN_ACTIONS_DELAY = 3 days;
    uint256 public constant MIN_RAMP_TIME = 1 days;

    address[N_COINS] public coins;
    uint256[N_COINS] public balances;
    uint256 public fee; // fee * 1e10.
    uint256 public admin_fee; // admin_fee * 1e10.
    uint256 public native_gas = 4029; // transfer native gas.

    IStableSwapLP public token;

    address constant NATIVE_ADDRESS =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    bool support_native;

    uint256 public initial_amplification_coefficient;
    uint256 public future_amplification_coefficient;
    uint256 public initial_amplification_coefficient_time;
    uint256 public future_amplification_coefficient_time;

    uint256 public admin_actions_deadline;
    uint256 public future_fee;
    uint256 public future_admin_fee;

    uint256 public kill_deadline;
    uint256 public constant KILL_DEADLINE_DT = 2 * 30 days;
    bool public is_killed;

    address public immutable STABLESWAP_FACTORY;
    bool public isInitialized;

    event TokenExchange(
        address indexed buyer,
        uint256 sold_id,
        uint256 tokens_sold,
        uint256 bought_id,
        uint256 tokens_bought
    );
    event AddLiquidity(
        address indexed provider,
        uint256[N_COINS] token_amounts,
        uint256[N_COINS] fees,
        uint256 invariant,
        uint256 token_supply
    );
    event RemoveLiquidity(
        address indexed provider,
        uint256[N_COINS] token_amounts,
        uint256[N_COINS] fees,
        uint256 token_supply
    );
    event RemoveLiquidityOne(
        address indexed provider,
        uint256 index,
        uint256 token_amount,
        uint256 coin_amount
    );
    event RemoveLiquidityImbalance(
        address indexed provider,
        uint256[N_COINS] token_amounts,
        uint256[N_COINS] fees,
        uint256 invariant,
        uint256 token_supply
    );
    event CommitNewFee(
        uint256 indexed deadline,
        uint256 fee,
        uint256 admin_fee
    );
    event NewFee(uint256 fee, uint256 admin_fee);
    event RampA(
        uint256 old_A,
        uint256 new_A,
        uint256 initial_time,
        uint256 future_time
    );
    event StopRampA(uint256 A, uint256 t);
    event SetNativeGas(uint256 native_gas);
    event RevertParameters();
    event DonateAdminFees();
    event Kill();
    event Unkill();

    /**
     * @notice constructor
     */
    constructor() {
        STABLESWAP_FACTORY = msg.sender;
    }

    /**
     * @notice initialize
     * @param _coins: Addresses of ERC20 conracts of coins (c-tokens) involved
     * @param _amplification_coefficient: Amplification coefficient multiplied by n * (n - 1)
     * @param _fee: Fee to charge for exchanges
     * @param _admin_fee: Admin fee
     * @param _owner: Owner
     * @param _liquidity_pool: LP address
     */
    function initialize(
        address[N_COINS] memory _coins,
        uint256 _amplification_coefficient,
        uint256 _fee,
        uint256 _admin_fee,
        address _owner,
        address _liquidity_pool
    ) external {
        require(!isInitialized, "Operations: Already initialized");
        require(msg.sender == STABLESWAP_FACTORY, "Operations: Not factory");
        require(
            _amplification_coefficient <= MAX_AMPLIFICATION_COEFFICIENT,
            "_amplification_coefficient exceeds maximum"
        );
        require(_fee <= MAX_FEE, "_fee exceeds maximum");
        require(_admin_fee <= MAX_ADMIN_FEE, "_admin_fee exceeds maximum");
        isInitialized = true;
        for (uint256 i = 0; i < N_COINS; i++) {
            require(_coins[i] != address(0), "ZERO Address");
            uint256 coinDecimal;
            if (_coins[i] == NATIVE_ADDRESS) {
                coinDecimal = 18;
                support_native = true;
            } else {
                coinDecimal = IERC20Metadata(_coins[i]).decimals();
            }
            require(
                coinDecimal <= MAX_DECIMAL,
                "The maximum decimal cannot exceed 18"
            );
            //set PRECISION_MUL and  RATES
            PRECISION_MUL[i] = 10 ** (MAX_DECIMAL - coinDecimal);
            RATES[i] = PRECISION * PRECISION_MUL[i];
        }
        coins = _coins;
        initial_amplification_coefficient = _amplification_coefficient;
        future_amplification_coefficient = _amplification_coefficient;
        fee = _fee;
        admin_fee = _admin_fee;
        kill_deadline = block.timestamp + KILL_DEADLINE_DT;
        token = IStableSwapLP(_liquidity_pool);

        transferOwnership(_owner);
    }

    function get_amplification_coefficient() internal view returns (uint256) {
        //Handle ramping A up or down
        uint256 t1 = future_amplification_coefficient_time;
        uint256 A1 = future_amplification_coefficient;
        if (block.timestamp < t1) {
            uint256 A0 = initial_amplification_coefficient;
            uint256 t0 = initial_amplification_coefficient_time;
            // Expressions in uint256 cannot have negative numbers, thus "if"
            if (A1 > A0) {
                return A0 + ((A1 - A0) * (block.timestamp - t0)) / (t1 - t0);
            } else {
                return A0 - ((A0 - A1) * (block.timestamp - t0)) / (t1 - t0);
            }
        } else {
            // when t1 == 0 or block.timestamp >= t1
            return A1;
        }
    }

    function amplification_coefficient() external view returns (uint256) {
        return get_amplification_coefficient();
    }

    function _xp() internal view returns (uint256[N_COINS] memory result) {
        result = RATES;
        for (uint256 i = 0; i < N_COINS; i++) {
            result[i] = (result[i] * balances[i]) / PRECISION;
        }
    }

    function _xp_mem(
        uint256[N_COINS] memory _balances
    ) internal view returns (uint256[N_COINS] memory result) {
        result = RATES;
        for (uint256 i = 0; i < N_COINS; i++) {
            result[i] = (result[i] * _balances[i]) / PRECISION;
        }
    }

    function get_D(
        uint256[N_COINS] memory xp,
        uint256 amp
    ) internal pure returns (uint256) {
        uint256 S;
        for (uint256 i = 0; i < N_COINS; i++) {
            S += xp[i];
        }
        if (S == 0) {
            return 0;
        }

        uint256 Dprev;
        uint256 D = S;
        uint256 Ann = amp * N_COINS;
        for (uint256 j = 0; j < 255; j++) {
            uint256 D_P = D;
            for (uint256 k = 0; k < N_COINS; k++) {
                D_P = (D_P * D) / (xp[k] * N_COINS); // If division by 0, this will be borked: only withdrawal will work. And that is good
            }
            Dprev = D;
            D =
                ((Ann * S + D_P * N_COINS) * D) /
                ((Ann - 1) * D + (N_COINS + 1) * D_P);
            // Equality with the precision of 1
            if (D > Dprev) {
                if (D - Dprev <= 1) {
                    break;
                }
            } else {
                if (Dprev - D <= 1) {
                    break;
                }
            }
        }
        return D;
    }

    function get_D_mem(
        uint256[N_COINS] memory _balances,
        uint256 amp
    ) internal view returns (uint256) {
        return get_D(_xp_mem(_balances), amp);
    }

    function get_virtual_price() external view returns (uint256) {
        /**
        Returns portfolio virtual price (for calculating profit)
        scaled up by 1e18
        */
        uint256 D = get_D(_xp(), get_amplification_coefficient());
        /**
        D is in the units similar to DAI (e.g. converted to precision 1e18)
        When balanced, D = n * x_u - total virtual value of the portfolio
        */
        uint256 token_supply = token.totalSupply();
        return (D * PRECISION) / token_supply;
    }

    function calc_token_amount(
        uint256[N_COINS] memory amounts,
        bool deposit
    ) external view returns (uint256) {
        /**
        Simplified method to calculate addition or reduction in token supply at
        deposit or withdrawal without taking fees into account (but looking at
        slippage).
        Needed to prevent front-running, not for precise calculations!
        */
        uint256[N_COINS] memory _balances = balances;
        uint256 amp = get_amplification_coefficient();
        uint256 D0 = get_D_mem(_balances, amp);
        for (uint256 i = 0; i < N_COINS; i++) {
            if (deposit) {
                _balances[i] += amounts[i];
            } else {
                _balances[i] -= amounts[i];
            }
        }
        uint256 D1 = get_D_mem(_balances, amp);
        uint256 token_amount = token.totalSupply();
        uint256 difference;
        if (deposit) {
            difference = D1 - D0;
        } else {
            difference = D0 - D1;
        }
        return (difference * token_amount) / D0;
    }

    function add_liquidity(
        uint256[N_COINS] memory amounts,
        uint256 min_mint_amount
    ) external payable nonReentrant {
        //Amounts is amounts of c-tokens
        require(!is_killed, "Killed");
        if (!support_native) {
            require(msg.value == 0, "Inconsistent quantity"); // Avoid sending native by mistake.
        }
        uint256[N_COINS] memory fees;
        uint256 _fee = (fee * N_COINS) / (4 * (N_COINS - 1));
        uint256 _admin_fee = admin_fee;
        uint256 amp = get_amplification_coefficient();

        uint256 token_supply = token.totalSupply();
        //Initial invariant
        uint256 D0;
        uint256[N_COINS] memory old_balances = balances;
        if (token_supply > 0) {
            D0 = get_D_mem(old_balances, amp);
        }
        uint256[N_COINS] memory new_balances = [
            old_balances[0],
            old_balances[1]
        ];

        for (uint256 i = 0; i < N_COINS; i++) {
            if (token_supply == 0) {
                require(amounts[i] > 0, "Initial deposit requires all coins");
            }
            // balances store amounts of c-tokens
            new_balances[i] = old_balances[i] + amounts[i];
        }

        // Invariant after change
        uint256 D1 = get_D_mem(new_balances, amp);
        require(D1 > D0, "D1 must be greater than D0");

        // We need to recalculate the invariant accounting for fees
        // to calculate fair user's share
        uint256 D2 = D1;
        if (token_supply > 0) {
            // Only account for fees if we are not the first to deposit
            for (uint256 i = 0; i < N_COINS; i++) {
                uint256 ideal_balance = (D1 * old_balances[i]) / D0;
                uint256 difference;
                if (ideal_balance > new_balances[i]) {
                    difference = ideal_balance - new_balances[i];
                } else {
                    difference = new_balances[i] - ideal_balance;
                }

                fees[i] = (_fee * difference) / FEE_DENOMINATOR;
                balances[i] =
                    new_balances[i] -
                    ((fees[i] * _admin_fee) / FEE_DENOMINATOR);
                new_balances[i] -= fees[i];
            }
            D2 = get_D_mem(new_balances, amp);
        } else {
            balances = new_balances;
        }

        // Calculate, how much pool tokens to mint
        uint256 mint_amount;
        if (token_supply == 0) {
            mint_amount = D1; // Take the dust if there was any
        } else {
            mint_amount = (token_supply * (D2 - D0)) / D0;
        }
        require(mint_amount >= min_mint_amount, "Slippage screwed you");

        // Take coins from the sender
        for (uint256 i = 0; i < N_COINS; i++) {
            uint256 amount = amounts[i];
            address coin = coins[i];
            transfer_in(coin, amount);
        }

        // Mint pool tokens
        token.mint(msg.sender, mint_amount);

        emit AddLiquidity(
            msg.sender,
            amounts,
            fees,
            D1,
            token_supply + mint_amount
        );
    }

    function get_y(
        uint256 i,
        uint256 j,
        uint256 x,
        uint256[N_COINS] memory xp_
    ) internal view returns (uint256) {
        // x in the input is converted to the same price/precision
        require(
            (i != j) && (i < N_COINS) && (j < N_COINS),
            "Illegal parameter"
        );
        uint256 amp = get_amplification_coefficient();
        uint256 D = get_D(xp_, amp);
        uint256 c = D;
        uint256 S_;
        uint256 Ann = amp * N_COINS;

        uint256 _x;
        for (uint256 k = 0; k < N_COINS; k++) {
            if (k == i) {
                _x = x;
            } else if (k != j) {
                _x = xp_[k];
            } else {
                continue;
            }
            S_ += _x;
            c = (c * D) / (_x * N_COINS);
        }
        c = (c * D) / (Ann * N_COINS);
        uint256 b = S_ + D / Ann; // - D
        uint256 y_prev;
        uint256 y = D;

        for (uint256 m = 0; m < 255; m++) {
            y_prev = y;
            y = (y * y + c) / (2 * y + b - D);
            // Equality with the precision of 1
            if (y > y_prev) {
                if (y - y_prev <= 1) {
                    break;
                }
            } else {
                if (y_prev - y <= 1) {
                    break;
                }
            }
        }
        return y;
    }

    function get_amount_out(
        uint256 source_token,
        uint256 dest_token,
        uint256 amount_in
    ) external view returns (uint256) {
        // dx and dy in c-units
        uint256[N_COINS] memory rates = RATES;
        uint256[N_COINS] memory xp = _xp();

        uint256 x = xp[source_token] +
            ((amount_in * rates[source_token]) / PRECISION);
        uint256 y = get_y(source_token, dest_token, x, xp);
        uint256 dy = ((xp[dest_token] - y - 1) * PRECISION) / rates[dest_token];
        uint256 _fee = (fee * dy) / FEE_DENOMINATOR;
        return dy - _fee;
    }

    function get_dy_underlying(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view returns (uint256) {
        // dx and dy in underlying units
        uint256[N_COINS] memory xp = _xp();
        uint256[N_COINS] memory precisions = PRECISION_MUL;

        uint256 x = xp[i] + dx * precisions[i];
        uint256 y = get_y(i, j, x, xp);
        uint256 dy = (xp[j] - y - 1) / precisions[j];
        uint256 _fee = (fee * dy) / FEE_DENOMINATOR;
        return dy - _fee;
    }

    function exchange_to_native(
        uint256 amount_in,
        uint256 native_min_amount_out
    ) external payable nonReentrant returns (uint256) {
        require(support_native, "Cant exchange native without native support");

        if (coins[0] == NATIVE_ADDRESS) {
            return exchange(1, 0, amount_in, native_min_amount_out);
        } else {
            return exchange(0, 1, amount_in, native_min_amount_out);
        }
    }

    function exchange_from_native(
        uint256 min_amount_out
    ) external payable nonReentrant returns (uint256) {
        require(support_native, "Cant exchange native without native support");

        if (coins[0] == NATIVE_ADDRESS) {
            return exchange(0, 1, msg.value, min_amount_out);
        } else {
            return exchange(1, 0, msg.value, min_amount_out);
        }
    }

    function exchange(
        uint256 source_token,
        uint256 dest_token,
        uint256 amount_in,
        uint256 amount_out
    ) internal returns (uint256) {
        require(!is_killed, "Killed");
        if (!support_native) {
            require(msg.value == 0, "Inconsistent quantity"); // Avoid sending native by mistake.
        }

        uint256[N_COINS] memory old_balances = balances;
        uint256[N_COINS] memory xp = _xp_mem(old_balances);

        uint256 x = xp[source_token] +
            (amount_in * RATES[source_token]) /
            PRECISION;
        uint256 y = get_y(source_token, dest_token, x, xp);

        uint256 dy = xp[dest_token] - y - 1; //  -1 just in case there were some rounding errors
        uint256 dy_fee = (dy * fee) / FEE_DENOMINATOR;

        // Convert all to real units
        dy = ((dy - dy_fee) * PRECISION) / RATES[dest_token];
        require(
            dy >= amount_out,
            "Exchange resulted in fewer coins than expected"
        );

        uint256 dy_admin_fee = (dy_fee * admin_fee) / FEE_DENOMINATOR;
        dy_admin_fee = (dy_admin_fee * PRECISION) / RATES[dest_token];

        // Change balances exactly in same way as we change actual ERC20 coin amounts
        balances[source_token] = old_balances[source_token] + amount_in;
        // When rounding errors happen, we undercharge admin fee in favor of LP
        balances[dest_token] = old_balances[dest_token] - dy - dy_admin_fee;

        address iAddress = coins[source_token];
        if (iAddress == NATIVE_ADDRESS) {
            require(amount_in == msg.value, "Inconsistent quantity");
        } else {
            IERC20(iAddress).safeTransferFrom(
                msg.sender,
                address(this),
                amount_in
            );
        }
        address jAddress = coins[dest_token];
        transfer_out(jAddress, dy);
        return dy;
    }

    function remove_liquidity(
        uint256 _amount,
        uint256[N_COINS] memory min_amounts
    ) external nonReentrant {
        uint256 total_supply = token.totalSupply();
        uint256[N_COINS] memory amounts;
        uint256[N_COINS] memory fees; //Fees are unused but we've got them historically in event

        for (uint256 i = 0; i < N_COINS; i++) {
            uint256 value = (balances[i] * _amount) / total_supply;
            require(
                value >= min_amounts[i],
                "Withdrawal resulted in fewer coins than expected"
            );
            balances[i] -= value;
            amounts[i] = value;
            transfer_out(coins[i], value);
        }

        token.burnFrom(msg.sender, _amount); // dev: insufficient funds

        emit RemoveLiquidity(msg.sender, amounts, fees, total_supply - _amount);
    }

    function remove_liquidity_imbalance(
        uint256[N_COINS] memory amounts,
        uint256 max_burn_amount
    ) external nonReentrant {
        require(!is_killed, "Killed");

        uint256 token_supply = token.totalSupply();
        require(token_supply > 0, "dev: zero total supply");
        uint256 _fee = (fee * N_COINS) / (4 * (N_COINS - 1));
        uint256 _admin_fee = admin_fee;
        uint256 amp = get_amplification_coefficient();

        uint256[N_COINS] memory old_balances = balances;
        uint256[N_COINS] memory new_balances = [
            old_balances[0],
            old_balances[1]
        ];
        uint256 D0 = get_D_mem(old_balances, amp);
        for (uint256 i = 0; i < N_COINS; i++) {
            new_balances[i] -= amounts[i];
        }
        uint256 D1 = get_D_mem(new_balances, amp);
        uint256[N_COINS] memory fees;
        for (uint256 i = 0; i < N_COINS; i++) {
            uint256 ideal_balance = (D1 * old_balances[i]) / D0;
            uint256 difference;
            if (ideal_balance > new_balances[i]) {
                difference = ideal_balance - new_balances[i];
            } else {
                difference = new_balances[i] - ideal_balance;
            }
            fees[i] = (_fee * difference) / FEE_DENOMINATOR;
            balances[i] =
                new_balances[i] -
                ((fees[i] * _admin_fee) / FEE_DENOMINATOR);
            new_balances[i] -= fees[i];
        }
        uint256 D2 = get_D_mem(new_balances, amp);

        uint256 token_amount = ((D0 - D2) * token_supply) / D0;
        require(token_amount > 0, "token_amount must be greater than 0");
        token_amount += 1; // In case of rounding errors - make it unfavorable for the "attacker"
        require(token_amount <= max_burn_amount, "Slippage screwed you");

        token.burnFrom(msg.sender, token_amount); // dev: insufficient funds

        for (uint256 i = 0; i < N_COINS; i++) {
            if (amounts[i] > 0) {
                transfer_out(coins[i], amounts[i]);
            }
        }
        token_supply -= token_amount;
        emit RemoveLiquidityImbalance(
            msg.sender,
            amounts,
            fees,
            D1,
            token_supply
        );
    }

    function get_y_D(
        uint256 A_,
        uint256 i,
        uint256[N_COINS] memory xp,
        uint256 D
    ) internal pure returns (uint256) {
        /**
        Calculate x[i] if one reduces D from being calculated for xp to D

        Done by solving quadratic equation iteratively.
        x_1**2 + x1 * (sum' - (A*n**n - 1) * D / (A * n**n)) = D ** (n + 1) / (n ** (2 * n) * prod' * A)
        x_1**2 + b*x_1 = c

        x_1 = (x_1**2 + c) / (2*x_1 + b)
        */
        // x in the input is converted to the same price/precision
        require(i < N_COINS, "dev: i above N_COINS");
        uint256 c = D;
        uint256 S_;
        uint256 Ann = A_ * N_COINS;

        uint256 _x;
        for (uint256 k = 0; k < N_COINS; k++) {
            if (k != i) {
                _x = xp[k];
            } else {
                continue;
            }
            S_ += _x;
            c = (c * D) / (_x * N_COINS);
        }
        c = (c * D) / (Ann * N_COINS);
        uint256 b = S_ + D / Ann;
        uint256 y_prev;
        uint256 y = D;

        for (uint256 k = 0; k < 255; k++) {
            y_prev = y;
            y = (y * y + c) / (2 * y + b - D);
            // Equality with the precision of 1
            if (y > y_prev) {
                if (y - y_prev <= 1) {
                    break;
                }
            } else {
                if (y_prev - y <= 1) {
                    break;
                }
            }
        }
        return y;
    }

    function _calc_withdraw_one_coin(
        uint256 _token_amount,
        uint256 i
    ) internal view returns (uint256, uint256) {
        // First, need to calculate
        // * Get current D
        // * Solve Eqn against y_i for D - _token_amount
        uint256 amp = get_amplification_coefficient();
        uint256 _fee = (fee * N_COINS) / (4 * (N_COINS - 1));
        uint256[N_COINS] memory precisions = PRECISION_MUL;
        uint256 total_supply = token.totalSupply();

        uint256[N_COINS] memory xp = _xp();

        uint256 D0 = get_D(xp, amp);
        uint256 D1 = D0 - (_token_amount * D0) / total_supply;
        uint256[N_COINS] memory xp_reduced = xp;

        uint256 new_y = get_y_D(amp, i, xp, D1);
        uint256 dy_0 = (xp[i] - new_y) / precisions[i]; // w/o fees

        for (uint256 k = 0; k < N_COINS; k++) {
            uint256 dx_expected;
            if (k == i) {
                dx_expected = (xp[k] * D1) / D0 - new_y;
            } else {
                dx_expected = xp[k] - (xp[k] * D1) / D0;
            }
            xp_reduced[k] -= (_fee * dx_expected) / FEE_DENOMINATOR;
        }
        uint256 dy = xp_reduced[i] - get_y_D(amp, i, xp_reduced, D1);
        dy = (dy - 1) / precisions[i]; // Withdraw less to account for rounding errors

        return (dy, dy_0 - dy);
    }

    function calc_withdraw_one_coin(
        uint256 _token_amount,
        uint256 i
    ) external view returns (uint256) {
        (uint256 dy, ) = _calc_withdraw_one_coin(_token_amount, i);
        return dy;
    }

    function remove_liquidity_one_coin(
        uint256 _token_amount,
        uint256 i,
        uint256 min_amount
    ) external nonReentrant {
        // Remove _amount of liquidity all in a form of coin i
        require(!is_killed, "Killed");
        (uint256 dy, uint256 dy_fee) = _calc_withdraw_one_coin(
            _token_amount,
            i
        );
        require(dy >= min_amount, "Not enough coins removed");

        balances[i] -= (dy + (dy_fee * admin_fee) / FEE_DENOMINATOR);
        token.burnFrom(msg.sender, _token_amount); // dev: insufficient funds
        transfer_out(coins[i], dy);

        emit RemoveLiquidityOne(msg.sender, i, _token_amount, dy);
    }

    function transfer_out(address coin_address, uint256 value) internal {
        if (coin_address == NATIVE_ADDRESS) {
            _safeTransferNative(msg.sender, value);
        } else {
            IERC20(coin_address).safeTransfer(msg.sender, value);
        }
    }

    function transfer_in(address coin_address, uint256 value) internal {
        if (coin_address == NATIVE_ADDRESS) {
            require(value == msg.value, "Inconsistent quantity");
        } else {
            IERC20(coin_address).safeTransferFrom(
                msg.sender,
                address(this),
                value
            );
        }
    }

    function _safeTransferNative(address to, uint256 value) internal {
        (bool success, ) = to.call{gas: native_gas, value: value}("");
        require(success, "native transfer failed");
    }

    // Admin functions

    function set_native_gas(uint256 _native_gas) external onlyOwner {
        require(
            _native_gas >= MIN_NATIVE_GAS && _native_gas <= MAX_NATIVE_GAS,
            "Illegal gas"
        );
        native_gas = _native_gas;
        emit SetNativeGas(_native_gas);
    }

    function ramp_amplification_coefficient(
        uint256 _future_amplification_coefficient,
        uint256 _future_time
    ) external onlyOwner {
        require(
            block.timestamp >=
                initial_amplification_coefficient_time + MIN_RAMP_TIME,
            "dev : too early"
        );
        require(
            _future_time >= block.timestamp + MIN_RAMP_TIME,
            "dev: insufficient time"
        );

        uint256 _initial_amplification_coefficient = get_amplification_coefficient();
        require(
            _future_amplification_coefficient > 0 &&
                _future_amplification_coefficient <
                MAX_AMPLIFICATION_COEFFICIENT,
            "_future_amplification_coefficient must be between 0 and MAX_AMPLIFICATION_COEFFICIENT"
        );
        require(
            (_future_amplification_coefficient >=
                _initial_amplification_coefficient &&
                _future_amplification_coefficient <=
                _initial_amplification_coefficient *
                    MAX_AMPLIFICATION_COEFFICIENT_CHANGE) ||
                (_future_amplification_coefficient <
                    _initial_amplification_coefficient &&
                    _future_amplification_coefficient *
                        MAX_AMPLIFICATION_COEFFICIENT_CHANGE >=
                    _initial_amplification_coefficient),
            "Illegal parameter _future_amplification_coefficient"
        );
        initial_amplification_coefficient = _initial_amplification_coefficient;
        future_amplification_coefficient = _future_amplification_coefficient;
        initial_amplification_coefficient_time = block.timestamp;
        future_amplification_coefficient_time = _future_time;

        emit RampA(
            _initial_amplification_coefficient,
            _future_amplification_coefficient,
            block.timestamp,
            _future_time
        );
    }

    function stop_rampget_amplification_coefficient() external onlyOwner {
        uint256 current_amplification_coefficient = get_amplification_coefficient();
        initial_amplification_coefficient = current_amplification_coefficient;
        future_amplification_coefficient = current_amplification_coefficient;
        initial_amplification_coefficient_time = block.timestamp;
        future_amplification_coefficient_time = block.timestamp;
        // now (block.timestamp < t1) is always False, so we return saved A

        emit StopRampA(current_amplification_coefficient, block.timestamp);
    }

    function commit_new_fee(
        uint256 new_fee,
        uint256 new_admin_fee
    ) external onlyOwner {
        require(
            admin_actions_deadline == 0,
            "admin_actions_deadline must be 0"
        ); // dev: active action
        require(new_fee <= MAX_FEE, "dev: fee exceeds maximum");
        require(
            new_admin_fee <= MAX_ADMIN_FEE,
            "dev: admin fee exceeds maximum"
        );

        admin_actions_deadline = block.timestamp + ADMIN_ACTIONS_DELAY;
        future_fee = new_fee;
        future_admin_fee = new_admin_fee;

        emit CommitNewFee(admin_actions_deadline, new_fee, new_admin_fee);
    }

    function apply_new_fee() external onlyOwner {
        require(
            block.timestamp >= admin_actions_deadline,
            "dev: insufficient time"
        );
        require(
            admin_actions_deadline != 0,
            "admin_actions_deadline should not be 0"
        );

        admin_actions_deadline = 0;
        fee = future_fee;
        admin_fee = future_admin_fee;

        emit NewFee(fee, admin_fee);
    }

    function revert_new_parameters() external onlyOwner {
        admin_actions_deadline = 0;
        emit RevertParameters();
    }

    function admin_balances(uint256 i) external view returns (uint256) {
        if (coins[i] == NATIVE_ADDRESS) {
            return address(this).balance - balances[i];
        } else {
            return IERC20(coins[i]).balanceOf(address(this)) - balances[i];
        }
    }

    function withdraw_admin_fees() external onlyOwner {
        for (uint256 i = 0; i < N_COINS; i++) {
            uint256 value;
            if (coins[i] == NATIVE_ADDRESS) {
                value = address(this).balance - balances[i];
            } else {
                value = IERC20(coins[i]).balanceOf(address(this)) - balances[i];
            }
            if (value > 0) {
                transfer_out(coins[i], value);
            }
        }
    }

    function donate_admin_fees() external onlyOwner {
        for (uint256 i = 0; i < N_COINS; i++) {
            if (coins[i] == NATIVE_ADDRESS) {
                balances[i] = address(this).balance;
            } else {
                balances[i] = IERC20(coins[i]).balanceOf(address(this));
            }
        }
        emit DonateAdminFees();
    }

    function kill_me() external onlyOwner {
        require(kill_deadline > block.timestamp, "Exceeded deadline");
        is_killed = true;
        emit Kill();
    }

    function unkill_me() external onlyOwner {
        is_killed = false;
        emit Unkill();
    }
}
