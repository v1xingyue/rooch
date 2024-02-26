// Copyright (c) RoochNetwork
// SPDX-License-Identifier: Apache-2.0

use anyhow::{Error, Result};
use move_core_types::language_storage::ModuleId;
use move_core_types::{
    account_address::AccountAddress,
    effects::{ChangeSet, Op},
    language_storage::{StructTag, TypeTag},
};
use moveos_types::move_types::as_struct_tag;
use moveos_types::moveos_std::account::Account;
use moveos_types::moveos_std::move_module::Module;
use moveos_types::moveos_std::object_id::ObjectID;
use moveos_types::state::{KeyState, TableState, TableStateSet};
use moveos_types::state::{MoveState, MoveStructType};
use moveos_types::state_resolver::StateKV;
use moveos_types::{
    h256::H256,
    moveos_std::move_module::MoveModule,
    state::{MoveStructState, State},
};
use moveos_types::{
    moveos_std::context,
    moveos_std::object::{ObjectEntity, RawObject},
    moveos_std::raw_table::TableInfo,
};
use moveos_types::{
    state::StateChangeSet,
    state_resolver::{self, module_id_to_key, resource_tag_to_key, StateResolver},
};
use smt::{NodeStore, SMTIterator, SMTree, UpdateSet};
use std::collections::BTreeMap;

use crate::state_store::NodeDBStore;

#[derive(Clone)]
pub struct TreeTable<NS> {
    smt: SMTree<KeyState, State, NS>,
}

impl<NS> TreeTable<NS>
where
    NS: NodeStore,
{
    pub fn new(node_store: NS) -> Self {
        Self::new_with_root(node_store, None)
    }

    pub fn new_with_root(node_store: NS, state_root: Option<H256>) -> Self {
        Self {
            smt: SMTree::new(node_store, state_root),
        }
    }

    pub fn get(&self, key: KeyState) -> Result<Option<State>> {
        self.smt.get(key)
    }

    pub fn list(&self, cursor: Option<KeyState>, limit: usize) -> Result<Vec<StateKV>> {
        self.smt.list(cursor, limit)
    }

    pub fn puts<I>(&self, update_set: I) -> Result<H256>
    where
        I: Into<UpdateSet<KeyState, State>>,
    {
        self.smt.puts(update_set)
    }

    pub fn state_root(&self) -> H256 {
        self.smt.root_hash()
    }

    pub fn put_modules(&self, modules: BTreeMap<ModuleId, Op<Vec<u8>>>) -> Result<H256> {
        //We wrap the modules to `MoveModule`
        //For distinguish `vector<u8>` and MoveModule in Move.
        self.put_changes(
            modules
                .into_iter()
                .map(|(k, v)| (module_id_to_key(&k), v.map(|v| MoveModule::new(v).into()))),
        )
    }

    pub fn put_resources(&self, modules: BTreeMap<StructTag, Op<Vec<u8>>>) -> Result<H256> {
        self.put_changes(modules.into_iter().map(|(k, v)| {
            (
                resource_tag_to_key(&k),
                v.map(|v| State::new(v, TypeTag::Struct(Box::new(k)))),
            )
        }))
    }

    pub fn put_changes<I: IntoIterator<Item = (KeyState, Op<State>)>>(
        &self,
        changes: I,
    ) -> Result<H256> {
        let mut update_set = UpdateSet::new();
        for (key, op) in changes {
            match op {
                Op::Modify(value) => {
                    update_set.put(key, value);
                }
                Op::Delete => {
                    update_set.remove(key);
                }
                Op::New(value) => {
                    update_set.put(key, value);
                }
            }
        }
        self.puts(update_set)
    }

    fn update_state_root(&self, new_state_root: H256) -> Result<()> {
        self.smt.update_state_root(new_state_root)?;
        Ok(())
    }

    pub fn dump(&self) -> Result<Vec<(KeyState, State)>> {
        self.smt.dump()
    }

    pub fn iter(&self) -> Result<SMTIterator<KeyState, State, NS>> {
        self.smt.iter(None)
    }
}

/// StateDB provide state storage and state proof
#[derive(Clone)]
pub struct StateDBStore {
    pub node_store: NodeDBStore,
    global_table: TreeTable<NodeDBStore>,
}

impl StateDBStore {
    pub fn new(node_store: NodeDBStore) -> Self {
        Self {
            node_store: node_store.clone(),
            global_table: TreeTable::new(node_store),
        }
    }

    pub fn new_with_root(node_store: NodeDBStore, state_root: Option<H256>) -> Self {
        Self {
            node_store: node_store.clone(),
            global_table: TreeTable::new_with_root(node_store, state_root),
        }
    }

    pub fn get(&self, id: ObjectID) -> Result<Option<State>> {
        self.global_table.get(id.to_key())
    }

    pub fn list(&self, cursor: Option<KeyState>, limit: usize) -> Result<Vec<StateKV>> {
        self.global_table.list(cursor, limit)
    }

    pub fn get_as_object<T: MoveStructState>(
        &self,
        id: ObjectID,
    ) -> Result<Option<ObjectEntity<T>>> {
        self.get(id)?
            .map(|state| state.as_object::<T>())
            .transpose()
            .map_err(Into::into)
    }

    pub fn get_as_raw_object(&self, id: ObjectID) -> Result<Option<RawObject>> {
        self.get(id)?
            .map(|state| state.as_raw_object())
            .transpose()
            .map_err(Into::into)
    }

    fn get_as_table(&self, id: ObjectID) -> Result<Option<(RawObject, TreeTable<NodeDBStore>)>> {
        let object = self.get_as_raw_object(id)?;
        match object {
            Some(object) => {
                let state_root = object.state_root;
                Ok(Some((
                    object,
                    TreeTable::new_with_root(
                        self.node_store.clone(),
                        Some(H256(state_root.into())),
                    ),
                )))
            }
            None => Ok(None),
        }
    }

    fn create_table(
        &self,
        id: ObjectID,
        is_resource_object: bool,
        account: Option<AccountAddress>,
    ) -> Result<(RawObject, TreeTable<NodeDBStore>)> {
        let table = TreeTable::new(self.node_store.clone());

        let object = if Module::module_object_id() == id {
            ObjectEntity::new_module_object().to_raw()
        } else if is_resource_object {
            let account = account.ok_or(anyhow::anyhow!(
                "Invalid account when create resource object"
            ))?;
            ObjectEntity::new_account_object(account).to_raw()
        } else {
            let table_info = TableInfo::new(AccountAddress::new(table.state_root().into()))?;
            ObjectEntity::new_table_object(id, table_info).to_raw()
        };
        Ok((object, table))
    }

    pub fn get_with_key(&self, id: ObjectID, key: KeyState) -> Result<Option<State>> {
        self.get_as_table(id)
            .and_then(|res| res.map(|(_, table)| table.get(key)).unwrap_or(Ok(None)))
    }

    pub fn list_with_key(
        &self,
        id: ObjectID,
        cursor: Option<KeyState>,
        limit: usize,
    ) -> Result<Vec<StateKV>> {
        let (_raw_object, table) = self
            .get_as_table(id.clone())?
            .ok_or_else(|| anyhow::format_err!("table with id {} not found", id))?;
        table.list(cursor, limit)
    }

    pub fn apply_change_set(
        &self,
        change_set: ChangeSet,
        state_change_set: StateChangeSet,
    ) -> Result<H256> {
        let mut account_resource_ids_mapping = BTreeMap::new();
        let mut changed_objects = UpdateSet::new();
        //TODO
        // We want deprecate the global storage instructions https://github.com/rooch-network/rooch/issues/248
        // So the ChangeSet should be empty, but we need the mutated accounts to init the resource object and module object
        // We need to figure out a way to init a fresh account.
        for (account, account_change_set) in change_set.into_inner() {
            let (modules, resources) = account_change_set.into_inner();
            debug_assert!(modules.is_empty() && resources.is_empty());

            account_resource_ids_mapping.insert(Account::account_object_id(account), account);
        }

        for (table_handle, table_change) in state_change_set.changes {
            // handle global object
            if table_handle == *context::GLOBAL_OBJECT_STORAGE_HANDLE {
                self.global_table
                    .put_changes(table_change.entries.into_iter())?;
                // TODO: do we need to update the size of global table?
            } else {
                let table_result_opt = self.get_as_table(table_handle.clone())?;
                let (mut raw_object, table) = match table_result_opt {
                    Some((raw_object, table)) => (raw_object, table),
                    None => {
                        let (is_resource_object, account) =
                            match account_resource_ids_mapping.get(&table_handle) {
                                Some(account) => (true, Some(*account)),
                                None => (false, None),
                            };
                        self.create_table(table_handle.clone(), is_resource_object, account)?
                    }
                };

                let new_state_root = table.put_changes(table_change.entries.into_iter())?;
                raw_object.state_root = AccountAddress::new(new_state_root.into());
                let curr_table_size: i64 = raw_object.size as i64;
                let updated_table_size = curr_table_size + table_change.size_increment;
                debug_assert!(updated_table_size >= 0);
                raw_object.size = updated_table_size as u64;
                changed_objects.put(table_handle.to_key(), raw_object.into_state()?);
            }
        }

        for table_handle in state_change_set.removed_tables {
            changed_objects.remove(table_handle.to_key());
        }

        self.global_table.puts(changed_objects)
    }

    pub fn is_genesis(&self) -> bool {
        self.global_table.smt.is_genesis()
    }

    pub fn resolve_state(&self, handle: &ObjectID, key: &KeyState) -> Result<Option<State>, Error> {
        if handle == &*state_resolver::GLOBAL_OBJECT_STORAGE_HANDLE {
            self.global_table.get(key.clone())
        } else {
            self.get_with_key(handle.clone(), key.clone())
        }
    }

    pub fn resolve_list_state(
        &self,
        handle: &ObjectID,
        cursor: Option<KeyState>,
        limit: usize,
    ) -> Result<Vec<StateKV>, Error> {
        if handle == &*state_resolver::GLOBAL_OBJECT_STORAGE_HANDLE {
            self.global_table.list(cursor, limit)
        } else {
            self.list_with_key(handle.clone(), cursor, limit)
        }
    }

    // rebuild statedb via TableStateSet from dump
    pub fn apply(&self, table_state_set: TableStateSet) -> Result<H256> {
        let mut state_root = H256::zero();
        for (k, v) in table_state_set.table_state_sets.into_iter() {
            if k == *state_resolver::GLOBAL_OBJECT_STORAGE_HANDLE {
                state_root = self.global_table.puts(v.entries)?
            } else {
                // must force create table
                let table_store = TreeTable::new(self.node_store.clone());
                state_root = table_store.puts(v.entries)?
            }
        }
        Ok(state_root)
    }

    // pub fn dump_iter(
    //     &self,
    //     handle: &ObjectID,
    // ) -> Result<Option<SMTIterator<Vec<u8>, State, NodeDBStore>>> {
    //     if handle == &*state_resolver::GLOBAL_OBJECT_STORAGE_HANDLE {
    //         self.global_table.iter().map(|v| Some(v))
    //     } else {
    //         self.get_as_table(handle.clone())
    //             .and_then(|res| res.map_or(Ok(None), |(_, table)| table.iter().map(|v| Some(v))))
    //     }
    // }

    // dump all states
    pub fn dump(&self) -> Result<TableStateSet> {
        let global_states = self.global_table.dump()?;
        let mut table_state_set = TableStateSet::default();
        let mut golbal_table_state = TableState::default();
        for (key, state) in global_states.into_iter() {
            // If the state is an Object, and the T's struct_tag of Object<T> is Table
            if ObjectID::struct_tag_match(&as_struct_tag(key.key_type.clone())?) {
                let mut table_state = TableState::default();
                let table_handle = ObjectID::from_bytes(&key.key)?;
                let result = self.get_as_table(table_handle.clone())?;
                if result.is_none() {
                    continue;
                };
                let (_table_object, table_store) = result.unwrap();
                let states = table_store.dump()?;
                for (inner_key, inner_state) in states.into_iter() {
                    table_state.entries.put(inner_key, inner_state);
                }
                table_state_set
                    .table_state_sets
                    .insert(table_handle, table_state);
            }

            golbal_table_state.entries.put(key, state);
        }
        table_state_set.table_state_sets.insert(
            context::GLOBAL_OBJECT_STORAGE_HANDLE.clone(),
            golbal_table_state,
        );

        Ok(table_state_set)
    }

    // update global table state root
    pub fn update_state_root(&self, new_state_root: H256) -> Result<()> {
        self.global_table.update_state_root(new_state_root)?;
        Ok(())
    }
}

impl StateResolver for StateDBStore {
    fn resolve_table_item(
        &self,
        handle: &ObjectID,
        key: &KeyState,
    ) -> std::result::Result<Option<State>, Error> {
        self.resolve_state(handle, key)
    }

    fn list_table_items(
        &self,
        handle: &ObjectID,
        cursor: Option<KeyState>,
        limit: usize,
    ) -> std::result::Result<Vec<StateKV>, Error> {
        self.resolve_list_state(handle, cursor, limit)
    }
}
