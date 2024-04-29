use std::{
    collections::HashMap,
    str,
    str::{FromStr, Utf8Error},
};

use aleph_client::{
    contract::{
        event::{translate_events, BlockDetails, ContractEvent},
        ContractInstance,
    },
    contract_transcode::{
        ContractMessageTranscoder,
        Value::{self, Seq},
    },
    pallets::contract::{ContractCallArgs, ContractRpc, ContractsUserApi},
    sp_weights::weight_v2::Weight,
    AccountId, AlephConfig, Connection, SignedConnectionApi, TxInfo, TxStatus,
};
use log::{error, info, trace};
use subxt::events::Events;
use thiserror::Error;

use crate::connections::azero::AzeroConnectionWithSigner;

#[derive(Debug, Error)]
#[error(transparent)]
#[non_exhaustive]
pub enum AzeroContractError {
    #[error("aleph-client error")]
    AlephClient(#[from] anyhow::Error),

    #[error("not account id")]
    NotAccountId(String),

    #[error("Invalid UTF-8 sequence")]
    InvalidUTF8(#[from] Utf8Error),

    #[error("Missing or invalid field")]
    MissingOrInvalidField(String),

    #[error("Dry-run reverted")]
    DryRunReverted(Result<Value, anyhow::Error>),

    #[error("Dispatch error")]
    DispatchError(String),
}

pub struct WrappedAzeroInstance {
    pub contract: ContractInstance,
    pub address: AccountId,
    pub transcoder: ContractMessageTranscoder,
    pub ref_time_limit: u64,
    pub proof_size_limit: u64,
}

impl WrappedAzeroInstance {
    pub fn new(
        address: &str,
        metadata_path: &str,
        ref_time_limit: u64,
        proof_size_limit: u64,
    ) -> Result<Self, AzeroContractError> {
        let address = AccountId::from_str(address)
            .map_err(|why| AzeroContractError::NotAccountId(why.to_string()))?;
        Ok(Self {
            address: address.clone(),
            contract: ContractInstance::new(address, metadata_path)?,
            transcoder: ContractMessageTranscoder::load(metadata_path)?,
            ref_time_limit,
            proof_size_limit,
        })
    }

    pub async fn deposit(
        &self,
        signed_connection: &AzeroConnectionWithSigner,
        amount: u128,
    ) -> Result<TxInfo, AzeroContractError> {
        let gas_limit = Weight {
            ref_time: self.ref_time_limit,
            proof_size: self.proof_size_limit,
        };

        let args: Vec<String> = vec![];
        let call_data = self.transcoder.encode("WrappedAZERO::deposit", &args)?;

        let call_result = signed_connection
            .call(
                self.address.clone(),
                amount,
                gas_limit,
                None,
                call_data,
                TxStatus::Finalized,
            )
            .await
            .map_err(AzeroContractError::AlephClient);
        info!("WrappedAZERO::deposit: {:?}", call_result);
        call_result
    }
}

pub struct AdvisoryInstance {
    pub contract: ContractInstance,
    pub address: AccountId,
}

impl AdvisoryInstance {
    pub fn new(address: &str, metadata_path: &str) -> Result<Self, AzeroContractError> {
        let address = AccountId::from_str(address)
            .map_err(|why| AzeroContractError::NotAccountId(why.to_string()))?;
        Ok(Self {
            address: address.clone(),
            contract: ContractInstance::new(address, metadata_path)?,
        })
    }

    pub async fn is_emergency(
        &self,
        connection: &Connection,
    ) -> Result<(bool, AccountId), AzeroContractError> {
        match self
            .contract
            .contract_read0::<bool, _>(connection, "is_emergency")
            .await
        {
            Ok(is_emergency) => Ok((is_emergency, self.address.clone())),
            Err(why) => Err(AzeroContractError::AlephClient(why)),
        }
    }
}

pub struct MostInstance {
    pub contract: ContractInstance,
    pub address: AccountId,
    pub transcoder: ContractMessageTranscoder,
    pub ref_time_limit: u64,
    pub proof_size_limit: u64,
}

impl MostInstance {
    pub fn new(
        address: &str,
        metadata_path: &str,
        ref_time_limit: u64,
        proof_size_limit: u64,
    ) -> Result<Self, AzeroContractError> {
        let address = AccountId::from_str(address)
            .map_err(|why| AzeroContractError::NotAccountId(why.to_string()))?;
        Ok(Self {
            address: address.clone(),
            transcoder: ContractMessageTranscoder::load(metadata_path)?,
            contract: ContractInstance::new(address, metadata_path)?,
            ref_time_limit,
            proof_size_limit,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn receive_request(
        &self,
        signed_connection: &AzeroConnectionWithSigner,
        request_hash: [u8; 32],
        committee_id: u128,
        dest_token_address: [u8; 32],
        amount: u128,
        dest_receiver_address: [u8; 32],
        request_nonce: u128,
    ) -> Result<TxInfo, AzeroContractError> {
        let gas_limit = Weight {
            ref_time: self.ref_time_limit,
            proof_size: self.proof_size_limit,
        };
        let args = [
            bytes32_to_str(&request_hash),
            committee_id.to_string(),
            bytes32_to_str(&dest_token_address),
            amount.to_string(),
            bytes32_to_str(&dest_receiver_address),
            request_nonce.to_string(),
        ];
        let call_data = self.transcoder.encode("receive_request", args)?;

        let dry_run_args = ContractCallArgs {
            origin: signed_connection.account_id().clone(),
            dest: self.address.clone(),
            value: 0,
            gas_limit: Some(gas_limit.clone()),
            storage_deposit_limit: None,
            input_data: call_data.clone(),
        };

        // Dry run to detect potential errors
        let dry_run_res = match signed_connection.call_and_get(dry_run_args).await?.result {
            Ok(res) => res,
            Err(why) => {
                error!("Dry run failed: {:?}", why);
                return Err(AzeroContractError::DispatchError(format!("{:?}", why)));
            }
        };
        if dry_run_res.did_revert() {
            let decoded_value = self
                .transcoder
                .decode_return("receive_request", &mut dry_run_res.data.as_ref());

            error!("Dry run reverted: {:?}", decoded_value);

            return Err(AzeroContractError::DryRunReverted(decoded_value));
        }

        let call_result = signed_connection
            .call(
                self.address.clone(),
                0,
                gas_limit,
                None,
                call_data,
                TxStatus::Finalized,
            )
            .await
            .map_err(AzeroContractError::AlephClient);
        info!("receive_request: {:?}", call_result);
        call_result
    }

    pub async fn is_halted(&self, connection: &Connection) -> Result<bool, AzeroContractError> {
        Ok(self
            .contract
            .contract_read0::<Result<bool, _>, _>(connection, "is_halted")
            .await??)
    }

    pub async fn _needs_signature(
        &self,
        connection: &Connection,
        request_hash: [u8; 32],
        account: AccountId,
        committee_id: u128,
    ) -> Result<bool, AzeroContractError> {
        Ok(self
            .contract
            .contract_read(
                connection,
                "needs_signature",
                &[
                    bytes32_to_str(&request_hash),
                    account.to_string(),
                    committee_id.to_string(),
                ],
            )
            .await?)
    }

    pub async fn current_committee_id(
        &self,
        connection: &Connection,
    ) -> Result<u128, AzeroContractError> {
        Ok(self
            .contract
            .contract_read0::<Result<u128, _>, _>(connection, "current_committee_id")
            .await??)
    }

    pub async fn is_in_committee(
        &self,
        connection: &Connection,
        committee_id: u128,
        account: AccountId,
    ) -> Result<bool, AzeroContractError> {
        Ok(self
            .contract
            .contract_read(
                connection,
                "is_in_committee",
                &[committee_id.to_string(), account.to_string()],
            )
            .await?)
    }

    pub fn filter_events(
        &self,
        events: Events<AlephConfig>,
        block_details: BlockDetails,
    ) -> Vec<ContractEvent> {
        translate_events(events.iter(), &[&self.contract], Some(block_details))
            .into_iter()
            .filter_map(|event_res| {
                if let Ok(event) = event_res {
                    Some(event)
                } else {
                    trace!("Failed to translate event: {:?}", event_res);
                    None
                }
            })
            .collect()
    }
}

#[derive(Debug)]
pub struct CrosschainTransferRequestData {
    pub committee_id: u128,
    pub dest_token_address: [u8; 32],
    pub amount: u128,
    pub dest_receiver_address: [u8; 32],
    pub request_nonce: u128,
}

pub fn get_request_event_data(
    data: &HashMap<String, Value>,
) -> Result<CrosschainTransferRequestData, AzeroContractError> {
    let committee_id: u128 = decode_uint_field(data, "committee_id")?;
    let dest_token_address: [u8; 32] = decode_seq_field(data, "dest_token_address")?;
    let amount: u128 = decode_uint_field(data, "amount")?;
    let dest_receiver_address: [u8; 32] = decode_seq_field(data, "dest_receiver_address")?;
    let request_nonce: u128 = decode_uint_field(data, "request_nonce")?;

    Ok(CrosschainTransferRequestData {
        committee_id,
        dest_token_address,
        amount,
        dest_receiver_address,
        request_nonce,
    })
}

fn decode_seq_field(
    data: &HashMap<String, Value>,
    field: &str,
) -> Result<[u8; 32], AzeroContractError> {
    if let Some(Seq(seq_data)) = data.get(field) {
        match seq_data
            .elems()
            .iter()
            .try_fold(Vec::new(), |mut v, x| match x {
                Value::UInt(x) => {
                    v.push(*x as u8);
                    Ok(v)
                }
                _ => Err(AzeroContractError::MissingOrInvalidField(format!(
                    "Seq under data field {:?} contains elements of incorrect type",
                    field
                ))),
            })?
            .try_into()
        {
            Ok(x) => Ok(x),
            Err(_) => Err(AzeroContractError::MissingOrInvalidField(format!(
                "Seq under data field {:?} has incorrect length",
                field
            ))),
        }
    } else {
        Err(AzeroContractError::MissingOrInvalidField(format!(
            "Data field {:?} couldn't be found or has incorrect format",
            field
        )))
    }
}

fn decode_uint_field(
    data: &HashMap<String, Value>,
    field: &str,
) -> Result<u128, AzeroContractError> {
    if let Some(Value::UInt(x)) = data.get(field) {
        Ok(*x)
    } else {
        Err(AzeroContractError::MissingOrInvalidField(format!(
            "Data field {:?} couldn't be found or has incorrect format",
            field
        )))
    }
}

fn bytes32_to_str(data: &[u8; 32]) -> String {
    "0x".to_owned() + &hex::encode(data)
}
