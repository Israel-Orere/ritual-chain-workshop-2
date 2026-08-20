// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RitualChain, IScheduler, IRitualWallet, ITEEServiceRegistry} from "./ritual/RitualChain.sol";

contract RitualPredict {
    enum MarketState { Open, Closed, Resolving, Resolved, Invalid }
    enum Comparator { GT, GTE, LT, LTE }
    enum Outcome { Unresolved, Yes, No }

    struct Market { uint256 id; address creator; string question; string oracleUrl; string jsonPath; uint256 target; Comparator comparator; uint64 closeBlock; uint64 resolveBlock; uint256 scheduleId; uint256 totalYes; uint256 totalNo; MarketState state; Outcome outcome; uint8 attempts; uint256 observedValue; string invalidReason; }
    struct NewMarket { string question; string oracleUrl; string jsonPath; uint256 target; Comparator comparator; uint256 bettingSeconds; uint256 resolveDelaySeconds; }

    uint32 public constant MAX_ATTEMPTS = 3;
    uint32 public constant RETRY_INTERVAL_BLOCKS = 200;
    uint32 public constant RESOLVE_GAS_LIMIT = 2_000_000;
    uint32 public constant SCHEDULER_TTL_BLOCKS = 150;
    uint256 public constant HTTP_TTL_BLOCKS = 100;
    uint256 public constant EXECUTOR_PROBES = 8;
    uint256 public constant MIN_MAX_FEE_PER_GAS = 1 gwei;
    uint256 public constant MIN_BETTING_SECONDS = 30;
    uint256 public constant MIN_RESOLVE_DELAY_SECONDS = 15;
    uint256 public constant MAX_MARKET_SECONDS = 1 days;

    uint256 public immutable blockTimeMs;
    uint256 public marketCount;
    mapping(uint256 => Market) private _markets;
    mapping(uint256 => mapping(address => uint256)) public yesStake;
    mapping(uint256 => mapping(address => uint256)) public noStake;
    mapping(uint256 => mapping(address => bool)) public settled;

    event MarketCreated(uint256 indexed marketId,address indexed creator,string question,uint64 closeBlock,uint64 resolveBlock,uint256 scheduleId);
    event ResolutionRuleSet(uint256 indexed marketId,string oracleUrl,string jsonPath,uint256 target,Comparator comparator);
    event BetPlaced(uint256 indexed marketId,address indexed bettor,bool isYes,uint256 amount);
    event ResolutionAttempted(uint256 indexed marketId,uint8 attempt,address executor);
    event ResolutionFailed(uint256 indexed marketId,uint8 attempt,string reason);
    event MarketResolved(uint256 indexed marketId,Outcome outcome,uint256 observedValue);
    event MarketInvalidated(uint256 indexed marketId,string reason);
    event WinningsClaimed(uint256 indexed marketId,address indexed claimant,uint256 amount);
    event StakeRefunded(uint256 indexed marketId,address indexed claimant,uint256 amount);

    error UnknownMarket(); error OnlyScheduler(); error BettingClosed(); error ZeroStake(); error NotResolved(); error NotInvalid(); error NothingToClaim(); error AlreadySettled(); error BadDuration(); error EmptyString(); error TransferFailed();

    constructor(uint256 blockTimeMs_) {
        if (blockTimeMs_ == 0) revert BadDuration();
        blockTimeMs = blockTimeMs_;
        // Ritual system contracts are not installed on a vanilla Hardhat network.
        // Skip only on Hardhat's standard local chain; real Ritual deployments still
        // perform the required scheduler approval in the constructor.
        if (block.chainid != 31337) IScheduler(RitualChain.SCHEDULER).approveScheduler(RitualChain.SCHEDULER);
    }

    function createMarket(NewMarket calldata p) external returns (uint256 marketId) {
        if(bytes(p.question).length==0||bytes(p.oracleUrl).length==0||bytes(p.jsonPath).length==0) revert EmptyString();
        if(p.bettingSeconds<MIN_BETTING_SECONDS||p.resolveDelaySeconds<MIN_RESOLVE_DELAY_SECONDS) revert BadDuration();
        if(p.bettingSeconds+p.resolveDelaySeconds>MAX_MARKET_SECONDS) revert BadDuration();
        uint256 close=block.number+_secondsToBlocks(p.bettingSeconds); uint256 resolve_=close+_secondsToBlocks(p.resolveDelaySeconds); if(resolve_>type(uint32).max) revert BadDuration();
        marketId=++marketCount; uint64 closeBlock=uint64(close); uint64 resolveBlock=uint64(resolve_); uint256 scheduleId=_scheduleResolution(marketId,resolveBlock);
        Market storage m=_markets[marketId]; m.id=marketId;m.creator=msg.sender;m.question=p.question;m.oracleUrl=p.oracleUrl;m.jsonPath=p.jsonPath;m.target=p.target;m.comparator=p.comparator;m.closeBlock=closeBlock;m.resolveBlock=resolveBlock;m.scheduleId=scheduleId;m.state=MarketState.Open;
        emit MarketCreated(marketId,msg.sender,p.question,closeBlock,resolveBlock,scheduleId); emit ResolutionRuleSet(marketId,p.oracleUrl,p.jsonPath,p.target,p.comparator);
    }
    function bet(uint256 marketId,bool isYes) external payable { Market storage m=_market(marketId);if(msg.value==0)revert ZeroStake();if(m.state!=MarketState.Open||block.number>=m.closeBlock)revert BettingClosed();if(isYes){yesStake[marketId][msg.sender]+=msg.value;m.totalYes+=msg.value;}else{noStake[marketId][msg.sender]+=msg.value;m.totalNo+=msg.value;}emit BetPlaced(marketId,msg.sender,isYes,msg.value); }
    function onScheduledResolve(uint256 executionIndex,uint256 marketId) external { if(msg.sender!=RitualChain.SCHEDULER)revert OnlyScheduler();Market storage m=_markets[marketId];if(m.closeBlock==0||m.state==MarketState.Resolved||m.state==MarketState.Invalid||block.number<m.closeBlock)return;uint8 attempt=m.attempts+1;m.attempts=attempt;m.state=MarketState.Resolving;address executor=_pickExecutor(marketId,executionIndex);emit ResolutionAttempted(marketId,attempt,executor);(bool ok,uint256 value,string memory reason)=_readOracle(m,executor);if(!ok){_fail(m,marketId,attempt,reason);return;}m.observedValue=value;bool yesWins=_compare(value,m.target,m.comparator);m.outcome=yesWins?Outcome.Yes:Outcome.No;uint256 winningPool=yesWins?m.totalYes:m.totalNo;if(winningPool==0){_cancelRemaining(m.scheduleId);_invalidate(m,marketId,"empty winning side");return;}m.state=MarketState.Resolved;_cancelRemaining(m.scheduleId);emit MarketResolved(marketId,m.outcome,value); }
    function _fail(Market storage m,uint256 marketId,uint8 attempt,string memory reason) private {emit ResolutionFailed(marketId,attempt,reason);if(attempt>=MAX_ATTEMPTS){_cancelRemaining(m.scheduleId);_invalidate(m,marketId,reason);}}
    function _invalidate(Market storage m,uint256 marketId,string memory reason) private {m.state=MarketState.Invalid;m.invalidReason=reason;emit MarketInvalidated(marketId,reason);}
    function claimWinnings(uint256 marketId) external {Market storage m=_market(marketId);if(m.state!=MarketState.Resolved)revert NotResolved();if(settled[marketId][msg.sender])revert AlreadySettled();uint256 payout=_payout(m,marketId,msg.sender);if(payout==0)revert NothingToClaim();settled[marketId][msg.sender]=true;emit WinningsClaimed(marketId,msg.sender,payout);_pay(msg.sender,payout);}
    function claimRefund(uint256 marketId) external {Market storage m=_market(marketId);if(m.state!=MarketState.Invalid)revert NotInvalid();if(settled[marketId][msg.sender])revert AlreadySettled();uint256 amount=yesStake[marketId][msg.sender]+noStake[marketId][msg.sender];if(amount==0)revert NothingToClaim();settled[marketId][msg.sender]=true;emit StakeRefunded(marketId,msg.sender,amount);_pay(msg.sender,amount);}
    function _payout(Market storage m,uint256 marketId,address account) private view returns(uint256){bool yesWon=m.outcome==Outcome.Yes;uint256 stake=yesWon?yesStake[marketId][account]:noStake[marketId][account];uint256 winningPool=yesWon?m.totalYes:m.totalNo;if(stake==0||winningPool==0)return 0;return(stake*(m.totalYes+m.totalNo))/winningPool;}
    function getMarket(uint256 marketId) public view returns(Market memory m){m=_markets[marketId];if(m.closeBlock==0)revert UnknownMarket();if(m.state==MarketState.Open&&block.number>=m.closeBlock)m.state=MarketState.Closed;}
    function getMarkets() external view returns(Market[] memory all){uint256 total=marketCount;all=new Market[](total);for(uint256 i=0;i<total;i++)all[i]=getMarket(total-i);}
    function stakesOf(uint256 marketId,address account) external view returns(uint256 yes,uint256 no,bool alreadySettled,uint256 claimable){Market storage m=_market(marketId);yes=yesStake[marketId][account];no=noStake[marketId][account];alreadySettled=settled[marketId][account];if(alreadySettled)return(yes,no,true,0);if(m.state==MarketState.Resolved)claimable=_payout(m,marketId,account);else if(m.state==MarketState.Invalid)claimable=yes+no;}
    function impliedOdds(uint256 marketId) external view returns(uint256 yesBps,uint256 noBps){Market storage m=_market(marketId);uint256 pool=m.totalYes+m.totalNo;if(pool==0)return(5000,5000);yesBps=(m.totalYes*10000)/pool;noBps=10000-yesBps;}
    function potentialPayout(uint256 marketId,address account,bool isYes,uint256 amount) external view returns(uint256){Market storage m=_market(marketId);uint256 yes=m.totalYes+(isYes?amount:0);uint256 no=m.totalNo+(isYes?0:amount);uint256 winningPool=isYes?yes:no;if(winningPool==0)return 0;uint256 stake=(isYes?yesStake[marketId][account]:noStake[marketId][account])+amount;return(stake*(yes+no))/winningPool;}
    function previewOutcome(uint256 observed,uint256 target,Comparator comparator) external pure returns(Outcome){return _compare(observed,target,comparator)?Outcome.Yes:Outcome.No;}
    function fundExecution(uint256 lockDurationBlocks) external payable {if(msg.value==0)revert ZeroStake();IRitualWallet(RitualChain.RITUAL_WALLET).deposit{value:msg.value}(lockDurationBlocks);}
    function executionBalance() external view returns(uint256){return IRitualWallet(RitualChain.RITUAL_WALLET).balanceOf(address(this));}
    function _readOracle(Market storage m,address executor) private returns(bool ok,uint256 value,string memory reason){if(executor==address(0))return(false,0,"no executor");bytes memory encoded=abi.encode(executor,new bytes[](0),HTTP_TTL_BLOCKS,new bytes[](0),bytes(""),m.oracleUrl,RitualChain.HTTP_GET,new string[](0),new string[](0),bytes(""),uint256(0),uint8(0),false);(bool callOk,bytes memory raw)=RitualChain.HTTP_PRECOMPILE.call(encoded);if(!callOk)return(false,0,"http precompile revert");if(raw.length==0)return(false,0,"empty http response");uint16 status;bytes memory body;string memory errorMessage;try this.decodeHttpResponse(raw) returns(uint16 s,bytes memory b,string memory e){status=s;body=b;errorMessage=e;}catch{return(false,0,"malformed HTTP envelope");}if(bytes(errorMessage).length>0)return(false,0,errorMessage);if(status!=200)return(false,0,"http status not 200");if(body.length==0)return(false,0,"empty body");(bool jqOk,uint256 parsed)=_jqUint(m.jsonPath,string(body));if(!jqOk)return(false,0,"jq parse failed");return(true,parsed,"");}
    function decodeHttpResponse(bytes calldata raw) external pure returns(uint16 status,bytes memory body,string memory errorMessage){(,bytes memory actualOutput)=abi.decode(raw,(bytes,bytes));require(actualOutput.length>0,"async output not settled");(status,,,body,errorMessage)=abi.decode(actualOutput,(uint16,string[],string[],bytes,string));}
    function _jqUint(string memory query,string memory json) private view returns(bool,uint256){(bool ok,bytes memory result)=RitualChain.JQ_PRECOMPILE.staticcall(abi.encode(query,json,RitualChain.JQ_OUT_UINT256));if(!ok||result.length<32)return(false,0);return(true,abi.decode(result,(uint256)));}
    function _pickExecutor(uint256 marketId,uint256 executionIndex) private view returns(address){uint256 seed=uint256(keccak256(abi.encode(marketId,executionIndex,block.number)));try ITEEServiceRegistry(RitualChain.TEE_SERVICE_REGISTRY).pickServiceByCapability(RitualChain.CAPABILITY_HTTP_CALL,true,seed,EXECUTOR_PROBES) returns(address teeAddress,bool found){return found?teeAddress:address(0);}catch{return address(0);}}
    function _scheduleResolution(uint256 marketId,uint64 resolveBlock) private returns(uint256 callId){if(block.chainid==31337)return marketId;bytes memory data=abi.encodeWithSelector(this.onScheduledResolve.selector,uint256(0),marketId);uint256 maxFeePerGas=block.basefee;if(maxFeePerGas<MIN_MAX_FEE_PER_GAS)maxFeePerGas=MIN_MAX_FEE_PER_GAS;callId=IScheduler(RitualChain.SCHEDULER).schedule(data,RESOLVE_GAS_LIMIT,uint32(resolveBlock),MAX_ATTEMPTS,RETRY_INTERVAL_BLOCKS,SCHEDULER_TTL_BLOCKS,maxFeePerGas,0,0,address(this));}
    function _cancelRemaining(uint256 scheduleId) private {if(scheduleId==0||block.chainid==31337)return;try IScheduler(RitualChain.SCHEDULER).cancel(scheduleId){}catch{}}
    function _market(uint256 marketId) private view returns(Market storage m){m=_markets[marketId];if(m.closeBlock==0)revert UnknownMarket();}
    function _compare(uint256 observed,uint256 target,Comparator comparator) private pure returns(bool){if(comparator==Comparator.GT)return observed>target;if(comparator==Comparator.GTE)return observed>=target;if(comparator==Comparator.LT)return observed<target;return observed<=target;}
    function _secondsToBlocks(uint256 seconds_) private view returns(uint256 blocks){blocks=(seconds_*1000)/blockTimeMs;if(blocks==0)blocks=1;}
    function _pay(address to,uint256 amount) private {(bool ok,)=payable(to).call{value:amount}("");if(!ok)revert TransferFailed();}
    receive() external payable {}
}
