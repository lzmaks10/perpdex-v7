// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUSDC {
    function transferFrom(address,address,uint256) external returns(bool);
    function transfer(address,uint256) external returns(bool);
}

contract PerpDEXV7 {
    // ── ERC20 LP Token ──
    string public constant name = "PerpDEX LP";
    string public constant symbol = "pLP";
    uint8 public constant decimals = 6;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function totalSupply() public view returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view returns (uint256) { return _balances[account]; }
    function allowance(address owner_, address spender) public view returns (uint256) { return _allowances[owner_][spender]; }

    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }
    function approve(address spender, uint256 amount) public returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(_allowances[from][msg.sender] >= amount, "!allow");
        _allowances[from][msg.sender] -= amount;
        _transfer(from, to, amount);
        return true;
    }
    function _transfer(address from, address to, uint256 amount) internal {
        require(_balances[from] >= amount, "!bal");
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }
    function _mint(address to, uint256 amount) internal {
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    function _burn(address from, uint256 amount) internal {
        _balances[from] -= amount;
        _totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    // ── DEX Core ──
    address public owner;
    address public usdc;
    uint256 public totalLiquidity;
    int256 public pendingPnL;
    uint256 public nextId = 1;
    uint256 public activePositions;

    enum Side { Long, Short }
    struct Position {
        address trader; Side side; uint8 pairIndex;
        uint256 margin; uint256 leverage; uint256 entryPrice; uint256 size; uint256 liqPrice; bool closed;
    }
    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) public userPositions;
    uint256[] public allIds;

    struct PairConfig {
        uint256 minMargin; uint256 maxLeverage; uint256 liqThreshold; uint256 fee; bool active;
    }
    mapping(uint8 => PairConfig) public pairs;

    event Deposited(address indexed u, uint256 a, uint256 lp);
    event Withdrawn(address indexed u, uint256 lp, uint256 a);
    event Opened(uint256 indexed id, address trader, uint8 pair, Side side, uint256 margin, uint256 leverage, uint256 entry, uint256 size);
    event Closed(uint256 indexed id, address trader, int256 pnl, uint256 payout);
    event Liquidated(uint256 indexed id, address trader, int256 pnl);

    modifier onlyOwner() { require(msg.sender == owner, "!owner"); _; }
    constructor(address _usdc) { owner = msg.sender; usdc = _usdc; }

    function deposit(uint256 a) external {
        require(IUSDC(usdc).transferFrom(msg.sender, address(this), a), "tx");
        uint256 lp = _totalSupply == 0 ? a : a * _totalSupply / totalLiquidity;
        totalLiquidity += a;
        _mint(msg.sender, lp);
        emit Deposited(msg.sender, a, lp);
    }

    function withdraw(uint256 lp) external {
        require(_balances[msg.sender] >= lp, "!bal");
        uint256 a = lp * totalLiquidity / _totalSupply;
        _burn(msg.sender, lp);
        totalLiquidity -= a;
        IUSDC(usdc).transfer(msg.sender, a);
        emit Withdrawn(msg.sender, lp, a);
    }

    function addPairs(uint8[] calldata idx, uint256[] calldata mm, uint256[] calldata ml, uint256[] calldata lt, uint256[] calldata f) external onlyOwner {
        for(uint i=0; i<idx.length; i++) pairs[idx[i]] = PairConfig(mm[i], ml[i], lt[i], f[i], true);
    }

    function openPosition(Side s, uint8 pi, uint256 m, uint256 lev, uint256 price) external {
        PairConfig storage c = pairs[pi];
        require(c.active && m >= c.minMargin && lev >= 100 && lev <= c.maxLeverage*100 && price > 0, "!p");
        IUSDC(usdc).transferFrom(msg.sender, address(this), m);
        totalLiquidity += m;
        uint256 pv = m * lev / 100;
        uint256 sz = pv * 1e8 / price;
        uint256 lq;
        if(s == Side.Long) lq = price * (lev - 100) / lev;
        else lq = price * (lev + 100) / lev;
        uint256 id = nextId++;
        positions[id] = Position(msg.sender, s, pi, m, lev, price, sz, lq, false);
        userPositions[msg.sender].push(id); allIds.push(id); activePositions++;
        emit Opened(id, msg.sender, pi, s, m, lev, price, sz);
    }

    function closePosition(uint256 id, uint256 price) external {
        Position storage p = positions[id];
        require(!p.closed && p.trader == msg.sender && price > 0, "!ok");
        p.closed = true; activePositions--;
        int256 pnl = _calcPnL(p, price);
        uint256 payout;
        if(pnl >= 0) { payout = p.margin + uint256(pnl); pendingPnL -= int256(uint256(pnl)); }
        else { uint256 loss = uint256(-pnl); payout = loss >= p.margin ? 0 : p.margin - loss; pendingPnL += int256(loss); }
        if(payout > totalLiquidity) payout = totalLiquidity;
        totalLiquidity -= payout;
        if(payout > 0) IUSDC(usdc).transfer(p.trader, payout);
        emit Closed(id, msg.sender, pnl, payout);
    }

    function liquidate(uint256 id, uint256 price) external {
        Position storage p = positions[id];
        require(!p.closed, "closed");
        uint256 pv = p.size * price / 1e8;
        uint256 pvLiq = p.size * p.liqPrice / 1e8;
        // Direction check + price safety (±10%)
        if(p.side == Side.Long) {
            require(pv <= pvLiq, "!liq");
            require(price >= p.liqPrice * 90 / 100, "price too low");
        } else {
            require(pv >= pvLiq, "!liq");
            require(price <= p.liqPrice * 110 / 100, "price too high");
        }
        p.closed = true; activePositions--;
        int256 pnl = _calcPnL(p, price);
        uint256 payout;
        if(pnl >= 0) { payout = p.margin + uint256(pnl); }
        else { uint256 loss = uint256(-pnl); payout = loss >= p.margin ? 0 : p.margin - loss; }
        // Keeper reward: 1% of margin
        uint256 kr = p.margin / 100; if(kr == 0) kr = 1;
        if(kr > payout) kr = payout;
        payout -= kr;
        // Cap total against liquidity
        uint256 total = payout + kr;
        if(total > totalLiquidity) { kr = kr * totalLiquidity / total; payout = totalLiquidity - kr; }
        totalLiquidity -= (payout + kr);
        if(kr > 0) IUSDC(usdc).transfer(msg.sender, kr);
        if(payout > 0) IUSDC(usdc).transfer(p.trader, payout);
        emit Liquidated(id, p.trader, pnl);
    }

    function _calcPnL(Position storage p, uint256 price) internal view returns(int256) {
        int256 e = int256(p.entryPrice); int256 c = int256(price); int256 s = int256(p.size);
        if(p.side == Side.Long) return (c - e) * s / 1e8; else return (e - c) * s / 1e8;
    }

    function getPosition(uint256 id) external view returns(Position memory) { return positions[id]; }
    function getUserPositions(address u) external view returns(uint256[] memory) { return userPositions[u]; }
    function getAllOpenPositions() external view returns(uint256[] memory) {
        uint256[] memory r = new uint256[](activePositions); uint256 j;
        for(uint i=0; i<allIds.length && j<activePositions; i++)
            if(!positions[allIds[i]].closed) r[j++] = allIds[i];
        return r;
    }
    function getUserLP(address u) external view returns (uint256) { return _balances[u]; }
    function getUserShare(address u) external view returns(uint256, uint256) {
        return (_balances[u] * totalLiquidity / (_totalSupply > 0 ? _totalSupply : 1), _balances[u] * 10000 / (_totalSupply > 0 ? _totalSupply : 1));
    }
}
