// Copyright (c) RoochNetwork
// SPDX-License-Identifier: Apache-2.0

use crate::cli_types::CommandAction;
use async_trait::async_trait;
use commands::{
    balance::BalanceCommand, create::CreateCommand, export::ExportCommand, import::ImportCommand,
    list::ListCommand, nullify::NullifyCommand, sign::SignCommand, switch::SwitchCommand,
    transfer::TransferCommand,
};
use rooch_types::error::RoochResult;
use std::path::PathBuf;

pub mod commands;
/// Tool for interacting with accounts
#[derive(clap::Parser)]
pub struct Account {
    #[clap(subcommand)]
    cmd: AccountCommand,
    /// Sets the file storing the state of our user accounts (an empty one will be created if missing)
    #[clap(long = "client.config")]
    config: Option<PathBuf>,
}

#[async_trait]
impl CommandAction<String> for Account {
    async fn execute(self) -> RoochResult<String> {
        match self.cmd {
            AccountCommand::Create(create) => create.execute_serialized().await,
            AccountCommand::List(list) => list.execute_serialized().await,
            AccountCommand::Switch(switch) => switch.execute_serialized().await,
            AccountCommand::Nullify(nullify) => nullify.execute_serialized().await,
            AccountCommand::Balance(balance) => balance.execute_serialized().await,
            AccountCommand::Transfer(transfer) => transfer.execute_serialized().await,
            AccountCommand::Export(export) => export.execute_serialized().await,
            AccountCommand::Import(import) => import.execute_serialized().await,
            AccountCommand::Sign(sign) => sign.execute_serialized().await,
        }
    }
}

#[derive(Debug, clap::Subcommand)]
#[clap(name = "account")]
pub enum AccountCommand {
    Create(CreateCommand),
    List(ListCommand),
    Switch(SwitchCommand),
    Nullify(NullifyCommand),
    Balance(BalanceCommand),
    Transfer(TransferCommand),
    Export(ExportCommand),
    Import(ImportCommand),
    Sign(SignCommand),
}
