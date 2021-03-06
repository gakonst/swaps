pragma solidity ^0.5.10;

import {BytesLib} from "@summa-tx/bitcoin-spv-sol/contracts/BytesLib.sol";
import {BTCUtils} from "@summa-tx/bitcoin-spv-sol/contracts/BTCUtils.sol";
import {ValidateSPV} from "@summa-tx/bitcoin-spv-sol/contracts/ValidateSPV.sol";

import {SafeMath} from "openzeppelin-solidity/contracts/math/SafeMath.sol";

interface IStatelessSwap {

    event ListingActive(
        bytes32 indexed _listingID,
        address indexed _seller,
        address indexed _asset,
        uint256 _value,
        bytes _partialTx,
        uint256 _reqDiff
    );

    event ListingClosed(
        bytes32 indexed _listingID,
        address _seller,
        address indexed _bidder,
        address indexed _asset,
        uint256 _value
    );

    /// @notice                 Seller opens listing by committing ethereum
    /// @param _partialTx       Seller's partial transaction
    /// @param _reqDiff         Minimum acceptable block difficulty summation
    /// @param _asset           The address of the asset contract. address(0) for ETH
    /// @param _value           The amount of asset for sale, in smallest possible units
    /// @return                 true if Seller post is valid, false otherwise
    function open(
        bytes calldata _partialTx,
        uint256 _reqDiff,
        address _asset,
        uint256 _value
    ) external payable returns (bytes32);

    /// @notice             Validate selected bid, bidder claims eth
    /// @param _version     The 4-byte tx version
    /// @param _vin         The length-prepended tx input vector
    /// @param _vout        The  length-prepended tx output vector
    /// @param _locktime    The 4-byte tx locktime
    /// @param _proof       The merkle proof of inclusion
    /// @param _index       Merkle proof leaf index to aid verification
    /// @param _headers     The raw bytes of all headers in order from earliest to latest
    /// @return             true if bid is successfully accepted, error otherwise
    function claim(
        bytes calldata _proof,
        uint _index,
        bytes calldata _version,
        bytes calldata _vin,
        bytes calldata _vout,
        bytes calldata _locktime,
        bytes calldata _headers
    ) external returns (bool);

    /// @notice             Validates the submitted bid transaction
    /// @dev                Uses bitcoin parsing tools. This could be made more gas efficient
    /// @param _version     The 4-byte tx version
    /// @param _vin         The length-prepended tx input vector
    /// @param _vout        The  length-prepended tx output vector
    /// @param _locktime    The 4-byte tx locktime
    /// @return             The txid
    function checkTx(
        bytes calldata _version,
        bytes calldata _vin,
        bytes calldata _vout,
        bytes calldata _locktime
    ) external pure returns (bytes32 _txid);

    /// @notice             Validates submitted header chain
    /// @dev                Checks that all headers are linked, that each meets its target difficulty
    /// @param _headers     The raw byte header chain
    /// @return             The total difficulty of the header chain, and the first header's tx tree root
    function checkHeaders(
        bytes calldata _headers
    ) external view returns (uint256 _diff, bytes32 _merkleRoot);

    /// @notice             Validates submitted merkle inclusion proof
    /// @dev                Takes in the x
    /// @param _txid        The 32 byte txid
    /// @param _merkleRoot  The block header's merkle root
    /// @param _proof       The inclusion proof
    /// @param _index       The index of the txid in the leaf set
    /// @return             true if _proof and _index show that _txid is in the _merkleRoot, else false
    function checkProof(
        bytes32 _txid,
        bytes32 _merkleRoot,
        bytes calldata _proof,
        uint256 _index
    ) external pure returns (bool);
}

contract StatelessSwap is IStatelessSwap {

    using BTCUtils for bytes;
    using BTCUtils for uint256;
    using BytesLib for bytes;
    using SafeMath for uint256;
    using ValidateSPV for bytes;
    using ValidateSPV for bytes32;

    enum ListingStates { NONE, ACTIVE, CLOSED }

    struct Listing {
        ListingStates state;
        uint256 value;                      // Asset amount or 721 ID
        uint256 reqDiff;                    // Required number of difficulty in confirmed blocks
        address asset;                      // Asset info
        address seller;                     // Seller address
        address wrapper;                    // The new NoFun (if applicable)

        // Filled Later
        address bidder;                     // Accepted bidder address
        bytes32 txid;                       // Accepted tx hash
    }

    address payable public developer;
    mapping(bytes32 => Listing) public listings;

    constructor (address _developer) public {
        developer = address(uint160(_developer));
    }

    // IMPLEMENT FOR SPECIFIC ASSET TYPES
    function ensureFunding(Listing storage _listing) internal;
    function distribute(Listing storage _listing) internal;

    /// @notice                 Seller opens listing by committing ethereum
    /// @param _partialTx       Seller's partial transaction
    /// @param _reqDiff         Minimum acceptable block difficulty summation
    /// @param _asset           The address of the asset contract. address(0) for ETH
    /// @param _value           The amount of asset for sale, in smallest possible units
    /// @return                 true if Seller post is valid, false otherwise
    function open(
        bytes calldata _partialTx,
        uint256 _reqDiff,
        address _asset,
        uint256 _value
    ) external payable returns (bytes32) {
        // Listing identifier is keccak256 of Seller's partial transaction outpoint
        bytes32 _listingID = keccak256(_partialTx.slice(7, 36));

        // Require unique listing identifier
        require(listings[_listingID].state == ListingStates.NONE, "Listing exists.");

        // Add to listings mapping
        listings[_listingID].state = ListingStates.ACTIVE;
        listings[_listingID].value = _value;
        if (_asset != address(0)) {
            listings[_listingID].asset = _asset;
        }
        listings[_listingID].seller = msg.sender;
        listings[_listingID].reqDiff = _reqDiff;

        ensureFunding(listings[_listingID]);

        // Emit ListingActive event
        emit ListingActive(
            _listingID,
            msg.sender,
            _asset,
            _value,
            _partialTx,
            _reqDiff);

        return _listingID;
    }

    /// @notice             Validate selected bid, bidder claims eth
    /// @param _proof       The merkle proof of inclusion
    /// @param _index       Merkle proof leaf index to aid verification
    /// @param _version     The 4-byte tx version
    /// @param _vin         The length-prepended tx input vector
    /// @param _vout        The  length-prepended tx output vector
    /// @param _locktime    The 4-byte tx locktime
    /// @param _headers     The raw bytes of all headers in order from earliest to latest
    /// @return             true if bid is successfully accepted, error otherwise
    function claim(
        bytes calldata _proof,
        uint _index,
        bytes calldata _version,
        bytes calldata _vin,
        bytes calldata _vout,
        bytes calldata _locktime,
        bytes calldata _headers
    ) external returns (bool) {
        uint256 _diff = _makeAllChecks(
            _proof,
            _index,
            _version,
            _vin,
            _vout,
            _locktime,
            _headers);

        bytes32 _listingID = keccak256(_vin.slice(1, 36));
        Listing storage _listing = listings[_listingID];

        // Require listing state to be ACTIVE and difficulty to be sufficient
        require(_diff >= _listing.reqDiff, "Not enough difficulty in header chain.");
        require(_listing.state == ListingStates.ACTIVE, "Listing has closed or does not exist.");
        address _bidder = _extractBidder(_vout);
        if (_bidder == address(0)) {
            _bidder = _listing.seller;
        }

        // Update listing state
        _listing.bidder = _bidder;
        _listing.state = ListingStates.CLOSED;

        distribute(_listing);

        // Emit ListingClosed event
        emit ListingClosed(
            _listingID,
            _listing.seller,
            _listing.bidder,
            _listing.asset,
            _listing.value
        );

        return true;
    }

    /// @notice         Extracts the bidder address from the bid tx
    /// @dev            Returns 0 if the op_return is weird or there's only 1 output
    /// @param _vout    The length-prefixed transaction output vector
    /// @return         The 20 byte bidder address from the op_return, or address(0)
    function _extractBidder(bytes memory _vout) internal pure returns (address _bidder) {
        _bidder = address(0);
        if (uint8(_vout[0]) > 1) {
            bytes memory _data = _vout.extractOutputAtIndex(1).extractOpReturnData();
            _bidder = _data.length >= 20 ? _data.toAddress(0) : address(0);
        }
    }

    /// @notice         Extracts the bidder address from the bid tx
    /// @dev            Returns 0 if the op_return is weird or there's only 1 output
    /// @param _vout    The length-prefixed transaction output vector
    /// @return         The 20 byte bidder address from the op_return, or address(0)
    function extractBidder(bytes calldata _vout) external pure returns (address _bidder) {
        return _extractBidder(_vout);
    }

    /// @notice             Validate everything about an spv proof
    /// @param _proof       The merkle proof of inclusion
    /// @param _index       Merkle proof leaf index to aid verification
    /// @param _version     The 4-byte tx version
    /// @param _vin         The length-prepended tx input vector
    /// @param _vout        The  length-prepended tx output vector
    /// @param _locktime    The 4-byte tx locktime
    /// @param _headers     The raw bytes of all headers in order from earliest to latest
    /// @return             The difficulty of the header chain, or error if there was an issue
    function _makeAllChecks(
        bytes memory _proof,
        uint _index,
        bytes memory _version,
        bytes memory _vin,
        bytes memory _vout,
        bytes memory _locktime,
        bytes memory _headers
    ) internal view returns (uint256 _diff) {
        bytes32 _merkleRoot;
        bytes32 _txid = _checkTx(_version, _vin, _vout, _locktime);
        (_diff, _merkleRoot) = _checkHeaders(_headers);
        _checkProof(_txid, _merkleRoot, _proof, _index);
    }

    /// @notice             Validate everything about an spv proof
    /// @param _proof       The merkle proof of inclusion
    /// @param _index       Merkle proof leaf index to aid verification
    /// @param _version     The 4-byte tx version
    /// @param _vin         The length-prepended tx input vector
    /// @param _vout        The  length-prepended tx output vector
    /// @param _locktime    The 4-byte tx locktime
    /// @param _headers     The raw bytes of all headers in order from earliest to latest
    /// @return             The difficulty of the header chain, or error if there was an issue
    function makeAllChecks(
        bytes calldata _proof,
        uint _index,
        bytes calldata _version,
        bytes calldata _vin,
        bytes calldata _vout,
        bytes calldata _locktime,
        bytes calldata _headers
    ) external view returns (uint256 _diff) {
        return _makeAllChecks(_proof, _index, _version, _vin, _vout, _locktime, _headers);
    }

    /// @notice             Validates the submitted bid transaction
    /// @dev                Uses bitcoin parsing tools. This could be made more gas efficient
    /// @param _version     The 4-byte tx version
    /// @param _vin         The length-prepended tx input vector
    /// @param _vout        The  length-prepended tx output vector
    /// @param _locktime    The 4-byte tx locktime
    /// @return             The txid
    function _checkTx(
        bytes memory _version,
        bytes memory _vin,
        bytes memory _vout,
        bytes memory _locktime
    ) internal pure returns (bytes32 _txid) {
        require(_vin.validateVin(), "vin is malformed");
        require(_vout.validateVout(), "vout is malformed");

        _txid = ValidateSPV.calculateTxId(_version, _vin, _vout, _locktime);
    }

    /// @notice             Validates the submitted bid transaction
    /// @dev                Uses bitcoin parsing tools. This could be made more gas efficient
    /// @param _version     The 4-byte tx version
    /// @param _vin         The length-prepended tx input vector
    /// @param _vout        The  length-prepended tx output vector
    /// @param _locktime    The 4-byte tx locktime
    /// @return             The txid, the bidder's ethereum address, and the value of the first output
    function checkTx(
        bytes calldata _version,
        bytes calldata _vin,
        bytes calldata _vout,
        bytes calldata _locktime
    ) external pure returns (bytes32 _txid) {
        return _checkTx(_version, _vin, _vout, _locktime);
    }

    /// @notice             Validates submitted header chain
    /// @dev                Checks that all headers are linked, that each meets its target difficulty
    /// @param _headers     The raw byte header chain
    /// @return             The total difficulty of the header chain, and the first header's tx tree root
    function _checkHeaders(
        bytes memory _headers
    ) internal view returns (uint256 _diff, bytes32 _merkleRoot) {
        _diff = _headers.validateHeaderChain();
        require(_diff != ValidateSPV.getErrBadLength(), "Header bytes not multiple of 80.");
        require(_diff != ValidateSPV.getErrInvalidChain(), "Header bytes not a valid chain.");
        require(_diff != ValidateSPV.getErrLowWork(), "Header does not meet its own difficulty target.");
        _merkleRoot = _headers.extractMerkleRootLE().toBytes32();
    }

    /// @notice             Validates submitted header chain
    /// @dev                Checks that all headers are linked, that each meets its target difficulty
    /// @param _headers     The raw byte header chain
    /// @return             The total difficulty of the header chain, and the first header's tx tree root
    function checkHeaders(
        bytes calldata _headers
    ) external view returns (uint256 _diff, bytes32 _merkleRoot) {
        return _checkHeaders(_headers);
    }

    /// @notice             Validates submitted merkle inclusion proof
    /// @dev                Takes in the x
    /// @param _txid        The 32 byte txid
    /// @param _merkleRoot  The block header's merkle root
    /// @param _proof       The inclusion proof
    /// @param _index       The index of the txid in the leaf set
    /// @return             true if _proof and _index show that _txid is in the _merkleRoot, else false
    function _checkProof(
        bytes32 _txid,
        bytes32 _merkleRoot,
        bytes memory _proof,
        uint256 _index
    ) internal pure returns (bool) {
        require(_txid.prove(_merkleRoot, _proof, _index), "Bad inclusion proof");
        return true;
    }

    /// @notice             Validates submitted merkle inclusion proof
    /// @dev                Takes in the x
    /// @param _txid        The 32 byte txid
    /// @param _merkleRoot  The block header's merkle root
    /// @param _proof       The inclusion proof
    /// @param _index       The index of the txid in the leaf set
    /// @return             true if _proof and _index show that _txid is in the _merkleRoot, else false
    function checkProof(
        bytes32 _txid,
        bytes32 _merkleRoot,
        bytes calldata _proof,
        uint256 _index
    ) external pure returns (bool) {
        return _checkProof(_txid, _merkleRoot, _proof, _index);
    }

    /// @notice             Calculates the developer's fee
    /// @dev                Looks up the listing and calculates a 25bps fee. Do not use for erc721.
    /// @param _value       The amount of value to split between bidder and developer
    /// @return             The fee share and the bidder's share
    function _allocate(uint256 _value) internal pure returns (uint256, uint256) {
        // developer share
        uint256 _feeShare = _value.div(400);
        // Bidder share
        uint256 _bidderShare = _value.sub(_feeShare);
        return (_feeShare, _bidderShare);
    }

    /// @notice             Calculates the developer's fee
    /// @dev                Looks up the listing and calculates a 25bps fee. Do not use for erc721.
    /// @param _value       The amount of value to split between bidder and developer
    /// @return             The fee share and the bidder's share
    function allocate(uint256 _value) external pure returns (uint256, uint256) {
        return _allocate(_value);
    }
}
