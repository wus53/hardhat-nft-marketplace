// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

error NftMarketplace__PriceMustBeAboveZero();
error NftMarketplace__NotApprovedForMarketplace();
error NftMarketplace__AlreadyListed(address nftAddress, uint256 tokenId);
error NftMarketplace__NotListed(address nftAddress, uint256 tokenId);
error NftMarketplace__NotOwner();
error NftMarketplace__PriceNotMet(address nftAddress, uint256 tokenId, uint256 price);
error NftMarketplace__NoProceeds();
error NftMarketplace__TransferFailed();

contract NftMarketplace is ReentrancyGuard {
    struct Listing {
        uint256 price;
        address seller;
    }

    event ItemListed(
        address indexed seller,
        address indexed nftAddress,
        uint256 indexed tokenId,
        uint256 price
    );

    event ItemBought(
        address indexed buyer,
        address indexed nftAddress,
        uint256 indexed tokenId,
        uint256 price
    );

    event ItemCanceled(
        address indexed seller,
        address indexed nftAddress,
        uint256 indexed tokenId
    );

    // NFT Contract address -> NFT Token ID -> Listing
    mapping(address => mapping(uint256 => Listing)) private nftListings;

    // Seller address -> Amount earned
    mapping(address => uint256) private sellerProceeds;

    ////////////////////
    //    Modifiers   //
    ////////////////////

    // modifier checks if the NFT has not been listed
    modifier notListed(address nftAddress, uint256 tokenId) {
        Listing memory listing = nftListings[nftAddress][tokenId];
        if (listing.price > 0) {
            revert NftMarketplace__AlreadyListed(nftAddress, tokenId);
        }
        _;
    }

    // modifier checks if the NFT is already listed
    modifier isListed(address nftAddress, uint256 tokenId) {
        Listing memory listing = nftListings[nftAddress][tokenId];
        if (listing.price <= 0) {
            revert NftMarketplace__NotListed(nftAddress, tokenId);
        }
        _;
    }

    // modifier checks if the spender is owner or not
    modifier isOwner(
        address nftAddress,
        uint256 tokenId,
        address spender
    ) {
        IERC721 nft = IERC721(nftAddress);
        address owner = nft.ownerOf(tokenId);
        if (spender != owner) {
            revert NftMarketplace__NotOwner();
        }
        _;
    }

    ////////////////////
    // Main Functions //
    ////////////////////

    /// @notice Method for listing NFT on the marketplace
    /// @param nftAddress: Address of the NFT
    /// @param tokenId: The token ID of the NFT
    /// @param price: Sale price of the listed NFT
    /// @dev Technically, we could have the contract be the escrow for the NFTs
    /// but this way people can still hold their NFTs when listed.
    function listItem(
        address nftAddress,
        uint256 tokenId,
        uint256 price
    )
        external
        // Challenge: Have this contract accept payment in a subset of tokens as well
        // Hint: Use Chainlink Price Feeds to convert the price of the tokens between each other
        notListed(nftAddress, tokenId)
        isOwner(nftAddress, tokenId, msg.sender)
    {
        if (price <= 0) {
            revert NftMarketplace__PriceMustBeAboveZero();
        }
        // 1. (less favored way) Send the NFT to the contract. Transfer -> Contract "hold" the NFT.
        // 2. (good) Owners can still hold their NFT, and give the marketplace approval
        // to sell the NFT for them. (ERC-712?)
        IERC721 nft = IERC721(nftAddress);
        if (nft.getApproved(tokenId) != address(this)) {
            revert NftMarketplace__NotApprovedForMarketplace();
        }
        // array? mapping? -> mapping
        nftListings[nftAddress][tokenId] = Listing(price, msg.sender);
        // emiting an Event is the best practice when updating a mapping
        emit ItemListed(msg.sender, nftAddress, tokenId, price);
    }

    /// @notice Method for buying NFT on the marketplace
    /// @param nftAddress: Address of the NFT
    /// @param tokenId: The token ID of the NFT
    /// @dev Be aware of potential re-entrancy attack vulnerability, avoid it by putting the
    /// transfer at the end of the function or using nonReentrant modifier from Openzeppelin
    function buyItem(
        address nftAddress,
        uint256 tokenId
    ) external payable nonReentrant isListed(nftAddress, tokenId) {
        Listing memory listedItem = nftListings[nftAddress][tokenId];
        if (msg.value < listedItem.price) {
            revert NftMarketplace__PriceNotMet(nftAddress, tokenId, listedItem.price);
        }
        // We don't just send the seller the money...
        // https://fravoll.github.io/solidity-patterns/pull_over_push.html
        // Sending the money to the user ❌
        // Have user withdraw the money ✅
        sellerProceeds[listedItem.seller] += msg.value;
        delete (nftListings[nftAddress][tokenId]);
        // safeTransferFrom is safer, look at the docs
        IERC721(nftAddress).safeTransferFrom(listedItem.seller, msg.sender, tokenId);
        emit ItemBought(msg.sender, nftAddress, tokenId, listedItem.price);
    }

    /// @notice Method for cancelling NFT on the marketplace
    /// @param nftAddress: Address of the NFT
    /// @param tokenId: The token ID of the NFT
    function cancelListing(
        address nftAddress,
        uint256 tokenId
    ) external isOwner(nftAddress, tokenId, msg.sender) isListed(nftAddress, tokenId) {
        delete (nftListings[nftAddress][tokenId]);
        emit ItemCanceled(msg.sender, nftAddress, tokenId);
    }

    /// @notice Method for updating the price of NFT on the marketplace
    /// @param nftAddress: Address of the NFT
    /// @param tokenId: The token ID of the NFT
    /// @param newPrice: Sale price of the listed NFT
    /// @dev Updating NFT is essentially re-listing the NFT with new price, so we can emit
    /// ItemListed event with new price.
    function updateListing(
        address nftAddress,
        uint256 tokenId,
        uint256 newPrice
    ) external isOwner(nftAddress, tokenId, msg.sender) isListed(nftAddress, tokenId) {
        if (newPrice <= 0) {
            revert NftMarketplace__PriceMustBeAboveZero();
        }
        nftListings[nftAddress][tokenId].price = newPrice;
        emit ItemListed(msg.sender, nftAddress, tokenId, newPrice);
    }

    /// @notice Method for withdrawing the user proceeds
    /// @dev `call` in combination with re-entrancy guard is the recommended method to use to
    /// send ether after December 2019.
    /// info related to `call` function:
    /// https://ethereum.stackexchange.com/questions/84313/get-return-value-of-a-low-level-call
    /// https://solidity-by-example.org/call/
    function withdrawProceeds() external {
        uint256 proceeds = sellerProceeds[msg.sender];
        if (proceeds <= 0) {
            revert NftMarketplace__NoProceeds();
        }
        // update the proceed before sending ether -> prevent re-entrancy
        sellerProceeds[msg.sender] = 0;
        (bool success, ) = payable(msg.sender).call{value: proceeds}("");
        if (!success) {
            revert NftMarketplace__TransferFailed();
        }
    }

    //////////////////////
    // Getter Functions //
    //////////////////////

    function getListing(
        address nftAddress,
        uint256 tokenId
    ) external view returns (Listing memory) {
        return nftListings[nftAddress][tokenId];
    }

    function getProceeds(address seller) external view returns (uint256) {
        return sellerProceeds[seller];
    }
}

//    1. `listItem`: List NFTs on the marketplace ✅
//    2. `buyItem`: Buy the NFTs ✅
//    3. `cancelItem`: Cancel a listing ✅
//    4. `updateListing`: Update Price ✅
//    5. `withdrawProceeds`: Withdraw payment from my bought NFTs ✅
