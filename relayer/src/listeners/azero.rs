use std::sync::Arc;

use aleph_client::{
    contract::{
        event::{translate_events, BlockDetails, ContractEvent},
        ContractInstance,
    },
    utility::BlocksApi,
    AlephConfig, AsConnection,
};
use ethers::{
    core::types::Address,
    prelude::ContractError,
    providers::{Provider, Ws},
};
use futures::StreamExt;
use log::info;
use subxt::{events::Events, utils::H256};
use thiserror::Error;

use crate::{
    config::Config,
    connections::{
        azero::SignedAzeroWsConnection,
        eth::{EthConnectionError, SignedEthWsConnection},
    },
    contracts::{AzeroContractError, Flipper, FlipperInstance},
    helpers::chunks,
};

#[derive(Debug, Error)]
#[error(transparent)]
#[non_exhaustive]
pub enum AzeroListenerError {
    #[error("aleph-client error")]
    AlephClient(#[from] anyhow::Error),

    #[error("error when parsing ethereum address")]
    FromHex(#[from] rustc_hex::FromHexError),

    #[error("provider error")]
    Subxt(#[from] subxt::Error),

    #[error("azero contract error")]
    AzeroContract(#[from] AzeroContractError),

    #[error("eth connection error")]
    EthConnection(#[from] EthConnectionError),

    #[error("eth contract error")]
    EthContract(#[from] ContractError<Provider<Ws>>),

    #[error("no block found")]
    BlockNotFound,
}

pub struct AzeroListener;

impl AzeroListener {
    pub async fn run(
        config: Arc<Config>,
        azero_connection: Arc<SignedAzeroWsConnection>,
        eth_connection: Arc<SignedEthWsConnection>,
    ) -> Result<(), AzeroListenerError> {
        let Config {
            azero_last_known_block,
            azero_contract_metadata,
            azero_contract_address,
            ..
        } = &*config;

        // replay past events from last known to the latest
        let last_block_number = azero_connection
            .get_block_number_opt(None)
            .await?
            .ok_or(AzeroListenerError::BlockNotFound)?;

        let instance = FlipperInstance::new(azero_contract_address, azero_contract_metadata)?;
        let contracts = vec![&instance.contract];

        for (from, to) in chunks(*azero_last_known_block as u32, last_block_number, 1000) {
            for block_number in from..to {
                let block_hash = azero_connection
                    .get_block_hash(block_number)
                    .await?
                    .ok_or(AzeroListenerError::BlockNotFound)?;

                let connection = azero_connection.as_connection();
                let events = connection
                    .as_client()
                    .blocks()
                    .at(block_hash)
                    .await?
                    .events()
                    .await?;

                // filter contract events
                handle_events(
                    Arc::clone(&eth_connection),
                    &config,
                    events,
                    &contracts,
                    block_number,
                    block_hash,
                )
                .await?;
            }
        }

        info!("finished processing past events");

        // subscribe to new events
        let connection = azero_connection.as_connection();
        let mut subscription = connection
            .as_client()
            .blocks()
            .subscribe_finalized()
            .await?;

        info!("subscribing to new events");

        while let Some(Ok(block)) = subscription.next().await {
            let events = block.events().await?;
            handle_events(
                Arc::clone(&eth_connection),
                &config,
                events,
                &contracts,
                block.number(),
                block.hash(),
            )
            .await?;
        }

        Ok(())
    }
}

async fn handle_events(
    eth_connection: Arc<SignedEthWsConnection>,
    config: &Config,
    events: Events<AlephConfig>,
    contracts: &[&ContractInstance],
    block_number: u32,
    block_hash: H256,
) -> Result<(), AzeroListenerError> {
    for event in translate_events(
        events.iter(),
        contracts,
        Some(BlockDetails {
            block_number,
            block_hash,
        }),
    ) {
        handle_event(Arc::clone(&eth_connection), config, event?).await?;
    }
    Ok(())
}

async fn handle_event(
    eth_connection: Arc<SignedEthWsConnection>,
    config: &Config,
    event: ContractEvent,
) -> Result<(), AzeroListenerError> {
    let Config {
        eth_contract_address,
        ..
    } = config;

    if let Some(name) = event.name {
        if name.eq("Flip") {
            info!("handling A0 contract event: {name}");

            let address = eth_contract_address.parse::<Address>()?;
            let contract = Flipper::new(address, Arc::new(&eth_connection));

            // TODO not executing
            contract
                .flop()
                .call()
                .await
                .expect("error commiting eth tx");
        }
    }
    Ok(())
}
