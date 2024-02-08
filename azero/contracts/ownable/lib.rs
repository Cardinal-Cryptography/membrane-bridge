#![cfg_attr(not(feature = "std"), no_std, no_main)]

/// This crate facilitates introducing the ownership of contracts and ownership changes using a two-step process.
///
/// The basic functionality is similar to the `Ownable` concept and exposes the following messages/methods:
/// * `get_owner`
/// * `is_owner`
/// * `ensure_owner`: a helper to use with the `?` syntax that will check whether the caller is the owner of the contract
///
/// Additionally, it introduces the following method for transferring ownership:
/// * `transfer_ownership`: callable only by the current owner, appoints the new owner but instead of making them the owner right away, it stores them in the `pending_owner` field
/// * `accept_owership`: callable only by the pending owner, removes the previous owner and makes them the sole owner of the contract
/// * `get_pending_owner`: returns the pending owner, if the ownership change process is currently underway.  
///
/// In order to use it in your contract, implement the methods of the `Ownable2Step` trait: in most cases, you can simply call the corresponding methods on the `Data` object.
use ink::primitives::AccountId;
use scale::{Decode, Encode};

#[derive(Debug, PartialEq, Eq, Encode, Decode)]
#[cfg_attr(feature = "std", derive(scale_info::TypeInfo))]
pub enum Error {
    /// The caller didn't have the permissions to call a given method
    UnauthorizedAccount(AccountId),
    /// The caller tried to accept ownership but the process hasn't been started
    NoPendingOwner,
    /// Useful in cases, when the `Data` struct is not accessed directly but inside of `Lazy` or a `Mapping`, means that we failed to access the `Data` struct itself.
    CorruptedStorage,
}

pub type OwnableResult<T> = Result<T, Error>;

#[derive(Debug)]
#[ink::storage_item]
pub struct Data {
    owner: AccountId,
    pending_owner: Option<AccountId>,
}

impl Data {
    pub fn new(owner: AccountId) -> Self {
        Self {
            owner,
            pending_owner: None,
        }
    }

    pub fn transfer_ownership(
        &mut self,
        caller: AccountId,
        new_owner: AccountId,
    ) -> OwnableResult<()> {
        if caller != self.owner {
            return Err(Error::UnauthorizedAccount(caller));
        }

        self.pending_owner = Some(new_owner);

        Ok(())
    }

    pub fn accept_ownership(&mut self, caller: AccountId) -> OwnableResult<()> {
        let pending_owner = self.pending_owner.ok_or(Error::NoPendingOwner)?;

        if caller != pending_owner {
            return Err(Error::UnauthorizedAccount(caller));
        }

        self.owner = pending_owner;
        self.pending_owner = None;

        Ok(())
    }

    pub fn get_owner(&self) -> AccountId {
        self.owner
    }

    pub fn get_pending_owner(&self) -> Option<AccountId> {
        self.pending_owner
    }

    pub fn is_owner(&self, caller: AccountId) -> bool {
        caller == self.owner
    }

    pub fn ensure_owner(&self, caller: AccountId) -> OwnableResult<()> {
        if caller != self.owner {
            Err(Error::UnauthorizedAccount(caller))
        } else {
            Ok(())
        }
    }
}

/// Implement this trait to enable two-step ownership trasfer process in your contract.
///
/// The process looks like this:
/// * current owner (Alice) calls `self.transfer_ownership(bob)`,
/// * the contract still has the owner: Alice and a pending owner: bob,
/// * when Bob claims the ownership by calling `self.accept_ownership()` he becomes the new owner and pending owner is removed.
///
/// The methods are all wrapper in `OwnableResult` to make it possible to use them in settings where the `Data` is e.g. behid `Lazy`.
#[ink::trait_definition]
pub trait Ownable2Step {
    /// Returns the address of the current owner.
    #[ink(message)]
    fn get_owner(&self) -> OwnableResult<AccountId>;

    /// Returns the address of the pending owner.
    #[ink(message)]
    fn get_pending_owner(&self) -> OwnableResult<AccountId>;

    /// Checks if the the `account` is the current owner.
    #[ink(message)]
    fn is_owner(&self, account: AccountId) -> OwnableResult<bool>;

    /// Starts the ownership transfer of the contract to a new account. Replaces the pending transfer if there is one.
    /// Can only be called by the current owner.
    #[ink(message)]
    fn transfer_ownership(&mut self, new_owner: AccountId) -> OwnableResult<()>;

    /// The new owner accepts the ownership transfer.
    #[ink(message)]
    fn accept_ownership(&mut self) -> OwnableResult<()>;

    /// Return error if called by any account other than the owner.
    #[ink(message)]
    fn ensure_owner(&self) -> OwnableResult<()>;
}
