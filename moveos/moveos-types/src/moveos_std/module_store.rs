// Copyright (c) RoochNetwork
// SPDX-License-Identifier: Apache-2.0

use crate::moveos_std::object;
use crate::moveos_std::object::ObjectID;
use crate::state::FieldKey;
use crate::{
    addresses::MOVEOS_STD_ADDRESS,
    state::{MoveStructState, MoveStructType},
};
use move_core_types::language_storage::StructTag;
use move_core_types::{
    account_address::AccountAddress,
    ident_str,
    identifier::IdentStr,
    value::{MoveStructLayout, MoveTypeLayout},
};
use serde::{Deserialize, Serialize};

pub const MODULE_NAME: &IdentStr = ident_str!("module_store");

#[derive(Eq, PartialEq, Debug, Clone, Deserialize, Serialize, Default)]
pub struct ModuleStore {
    //Move VM will auto add a bool field to the empty struct
    //So we manually add a bool field to the struct
    _placeholder: bool,
}

impl ModuleStore {
    pub fn object_id() -> ObjectID {
        object::named_object_id(&Self::struct_tag())
    }
}

impl MoveStructType for ModuleStore {
    const ADDRESS: AccountAddress = MOVEOS_STD_ADDRESS;
    const MODULE_NAME: &'static IdentStr = MODULE_NAME;
    const STRUCT_NAME: &'static IdentStr = ident_str!("ModuleStore");

    fn struct_tag() -> StructTag {
        StructTag {
            address: Self::ADDRESS,
            module: Self::MODULE_NAME.to_owned(),
            name: Self::STRUCT_NAME.to_owned(),
            type_params: vec![],
        }
    }
}

impl MoveStructState for ModuleStore {
    fn struct_layout() -> MoveStructLayout {
        MoveStructLayout::new(vec![MoveTypeLayout::Bool])
    }
}

///////////// Package ////////////////
#[derive(Eq, PartialEq, Debug, Clone, Deserialize, Serialize, Default)]
pub struct Package {
    // // Move VM will auto add a bool field to the empty struct
    // // So we manually add a bool field to the struct
    _placeholder: bool,
}

impl Package {
    pub fn package_id(module_address: &AccountAddress) -> ObjectID {
        let module_store_id = ModuleStore::object_id();
        module_store_id.child_id(Self::package_field_key(module_address))
    }

    ///Package field key, package is a special case, we directly use the module address as the field key, do not hash it
    pub fn package_field_key(module_address: &AccountAddress) -> FieldKey {
        (*module_address).into()
    }
}

impl MoveStructType for Package {
    const ADDRESS: AccountAddress = MOVEOS_STD_ADDRESS;
    const MODULE_NAME: &'static IdentStr = MODULE_NAME;
    const STRUCT_NAME: &'static IdentStr = ident_str!("Package");

    fn struct_tag() -> StructTag {
        StructTag {
            address: Self::ADDRESS,
            module: Self::MODULE_NAME.to_owned(),
            name: Self::STRUCT_NAME.to_owned(),
            type_params: vec![],
        }
    }
}

impl MoveStructState for Package {
    fn struct_layout() -> MoveStructLayout {
        MoveStructLayout::new(vec![MoveTypeLayout::Bool])
    }
}
