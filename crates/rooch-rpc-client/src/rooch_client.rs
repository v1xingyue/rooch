// Copyright (c) RoochNetwork
// SPDX-License-Identifier: Apache-2.0

use anyhow::{Ok, Result};
use jsonrpsee::http_client::HttpClient;
use moveos_types::h256::H256;
use moveos_types::moveos_std::account::Account;
use moveos_types::{access_path::AccessPath, state::ObjectState, transaction::FunctionCall};
use rooch_rpc_api::api::rooch_api::RoochAPIClient;
use rooch_rpc_api::jsonrpc_types::{
    account_view::BalanceInfoView, transaction_view::TransactionWithInfoView,
    DryRunTransactionResponseView,
};
use rooch_rpc_api::jsonrpc_types::{
    AccessPathView, AnnotatedFunctionResultView, BalanceInfoPageView, EventOptions, EventPageView,
    FieldKeyView, ObjectIDView, RoochAddressView, StateOptions, StatePageView, StructTagView,
};
use rooch_rpc_api::jsonrpc_types::{ExecuteTransactionResponseView, ObjectStateView};
use rooch_rpc_api::jsonrpc_types::{
    IndexerObjectStatePageView, ObjectStateFilterView, QueryOptions,
};
use rooch_rpc_api::jsonrpc_types::{TransactionWithInfoPageView, TxOptions};
use rooch_types::indexer::state::IndexerStateID;
use rooch_types::transaction::RoochTransactionData;
use rooch_types::{address::RoochAddress, transaction::rooch::RoochTransaction};
use std::sync::Arc;

#[derive(Clone, Debug)]
pub struct RoochRpcClient {
    http: Arc<HttpClient>,
}

// TODO: call args are uniformly defined in jsonrpc types?
// example execute_view_function get_events_by_event_handle

impl RoochRpcClient {
    pub fn new(http: Arc<HttpClient>) -> Self {
        Self { http }
    }

    pub async fn get_chain_id(&self) -> Result<u64> {
        Ok(self.http.get_chain_id().await?.0)
    }

    pub async fn execute_tx(
        &self,
        tx: RoochTransaction,
        tx_option: Option<TxOptions>,
    ) -> Result<ExecuteTransactionResponseView> {
        let tx_payload = bcs::to_bytes(&tx)?;
        self.http
            .execute_raw_transaction(tx_payload.into(), tx_option)
            .await
            .map_err(|e| anyhow::anyhow!(e))
    }

    pub async fn dry_run_tx(
        &self,
        tx: RoochTransactionData,
    ) -> Result<DryRunTransactionResponseView> {
        let tx_payload = bcs::to_bytes(&tx)?;
        self.http
            .dry_run(tx_payload.into())
            .await
            .map_err(|e| anyhow::anyhow!(e))
    }

    pub async fn execute_view_function(
        &self,
        function_call: FunctionCall,
    ) -> Result<AnnotatedFunctionResultView> {
        self.http
            .execute_view_function(function_call.into())
            .await
            .map_err(|e| anyhow::anyhow!(e))
    }

    pub async fn get_states(
        &self,
        access_path: AccessPath,
    ) -> Result<Vec<Option<ObjectStateView>>> {
        Ok(self.http.get_states(access_path.into(), None).await?)
    }

    pub async fn get_decoded_states(
        &self,
        access_path: AccessPath,
    ) -> Result<Vec<Option<ObjectStateView>>> {
        Ok(self
            .http
            .get_states(
                access_path.into(),
                Some(StateOptions::default().decode(true)),
            )
            .await?)
    }

    pub async fn get_decoded_states_with_display(
        &self,
        access_path: AccessPath,
    ) -> Result<Vec<Option<ObjectStateView>>> {
        Ok(self
            .http
            .get_states(
                access_path.into(),
                Some(StateOptions::default().decode(true).show_display(true)),
            )
            .await?)
    }

    pub async fn get_transactions_by_order(
        &self,
        cursor: Option<u64>,
        limit: Option<u64>,
        descending_order: Option<bool>,
    ) -> Result<TransactionWithInfoPageView> {
        Ok(self
            .http
            .get_transactions_by_order(
                cursor.map(Into::into),
                limit.map(Into::into),
                descending_order,
            )
            .await?)
    }

    pub async fn get_transactions_by_hash(
        &self,
        tx_hashes: Vec<H256>,
    ) -> Result<Vec<Option<TransactionWithInfoView>>> {
        Ok(self
            .http
            .get_transactions_by_hash(tx_hashes.iter().map(|hash| (*hash).into()).collect())
            .await?)
    }

    pub async fn get_sequence_number(&self, sender: RoochAddress) -> Result<u64> {
        Ok(self
            .get_states(AccessPath::object(Account::account_object_id(
                sender.into(),
            )))
            .await?
            .pop()
            .flatten()
            .map(|state_view| {
                let state = ObjectState::from(state_view);
                state.into_object_uncheck::<Account>()
            })
            .transpose()?
            .map_or(0, |account| account.value.sequence_number))
    }

    pub async fn get_events_by_event_handle(
        &self,
        event_handle_type: StructTagView,
        cursor: Option<u64>,
        limit: Option<u64>,
        descending_order: Option<bool>,
        event_options: Option<EventOptions>,
    ) -> Result<EventPageView> {
        let s = self
            .http
            .get_events_by_event_handle(
                event_handle_type,
                cursor.map(Into::into),
                limit.map(Into::into),
                descending_order,
                event_options,
            )
            .await?;
        Ok(s)
    }

    pub async fn list_states(
        &self,
        access_path: AccessPathView,
        cursor: Option<String>,
        limit: Option<u64>,
    ) -> Result<StatePageView> {
        Ok(self
            .http
            .list_states(access_path, cursor, limit.map(Into::into), None)
            .await?)
    }

    pub async fn get_field_states(
        &self,
        object_id: ObjectIDView,
        field_key: Vec<FieldKeyView>,
        state_option: Option<StateOptions>,
    ) -> Result<Vec<Option<ObjectStateView>>> {
        Ok(self
            .http
            .get_field_states(object_id, field_key, state_option)
            .await?)
    }

    pub async fn list_field_states(
        &self,
        object_id: ObjectIDView,
        cursor: Option<String>,
        limit: Option<u64>,
        state_option: Option<StateOptions>,
    ) -> Result<StatePageView> {
        Ok(self
            .http
            .list_field_states(object_id, cursor, limit.map(Into::into), state_option)
            .await?)
    }

    pub async fn list_decoded_states(
        &self,
        access_path: AccessPathView,
        cursor: Option<String>,
        limit: Option<u64>,
    ) -> Result<StatePageView> {
        Ok(self
            .http
            .list_states(
                access_path,
                cursor,
                limit.map(Into::into),
                Some(StateOptions::default().decode(true)),
            )
            .await?)
    }

    pub async fn get_balance(
        &self,
        account_addr: RoochAddressView,
        coin_type: StructTagView,
    ) -> Result<BalanceInfoView> {
        Ok(self
            .http
            .get_balance(account_addr.into(), coin_type)
            .await?)
    }

    pub async fn get_balances(
        &self,
        account_addr: RoochAddressView,
        cursor: Option<IndexerStateID>,
        limit: Option<u64>,
    ) -> Result<BalanceInfoPageView> {
        Ok(self
            .http
            .get_balances(
                account_addr.into(),
                cursor.map(Into::into),
                limit.map(Into::into),
            )
            .await?)
    }

    pub async fn query_object_states(
        &self,
        filter: ObjectStateFilterView,
        cursor: Option<IndexerStateID>,
        limit: Option<u64>,
        query_options: Option<QueryOptions>,
    ) -> Result<IndexerObjectStatePageView> {
        Ok(self
            .http
            .query_object_states(
                filter,
                cursor.map(Into::into),
                limit.map(Into::into),
                query_options,
            )
            .await?)
    }
}
