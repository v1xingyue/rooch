// Copyright (c) RoochNetwork
// SPDX-License-Identifier: Apache-2.0

// Copyright (c) The Move Contributors
// SPDX-License-Identifier: Apache-2.0

use move_binary_format::errors::PartialVMResult;
use move_vm_runtime::native_functions::{NativeContext, NativeFunction};
use move_vm_types::{
    loaded_data::runtime_types::Type, natives::function::NativeResult, values::Value,
};
use std::{collections::VecDeque, sync::Arc};

pub fn make_module_natives(
    natives: impl IntoIterator<Item = (impl Into<String>, NativeFunction)>,
) -> impl Iterator<Item = (String, NativeFunction)> {
    natives
        .into_iter()
        .map(|(func_name, func)| (func_name.into(), func))
}

pub fn make_native<G>(
    gas_params: G,
    func: impl Fn(&G, &mut NativeContext, Vec<Type>, VecDeque<Value>) -> PartialVMResult<NativeResult>
        + Sync
        + Send
        + 'static,
) -> NativeFunction
where
    G: Send + Sync + 'static,
{
    Arc::new(
        move |context, ty_args, args| -> PartialVMResult<NativeResult> {
            let result = func(&gas_params, context, ty_args, args);
            if cfg!(debug_assertions) {
                match &result {
                    Err(err) => {
                        log::debug!("Error in native function: {:?}", err);
                    }
                    Ok(res) => match res {
                        NativeResult::Success {
                            cost: _,
                            ret_vals: _,
                        } => {}
                        NativeResult::Abort { cost, abort_code } => {
                            log::debug!(
                                "Abort in native function: cost: {:?}, abort_code: {:?}",
                                cost,
                                abort_code
                            );
                        }
                        NativeResult::OutOfGas { partial_cost } => {
                            log::debug!(
                                "OutOfGas in native function: partial_cost: {:?}",
                                partial_cost
                            );
                        }
                    },
                }
            }
            result
        },
    )
}
