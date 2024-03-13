// Copyright (c) RoochNetwork
// SPDX-License-Identifier: Apache-2.0

/// Move Object
/// For more details, please refer to https://rooch.network/docs/developer-guides/object
module moveos_std::object {
    use moveos_std::signer;
    use moveos_std::object_id::{Self, ObjectID};
    use moveos_std::raw_table;
    use moveos_std::tx_context;

    friend moveos_std::context;
    friend moveos_std::account;
    friend moveos_std::move_module;
    friend moveos_std::storage_context;
    friend moveos_std::event;
    friend moveos_std::table;
    friend moveos_std::type_table;

    const ErrorObjectAlreadyExist: u64 = 1;
    const ErrorObjectFrozen: u64 = 2;
    const ErrorInvalidOwnerAddress:u64 = 3;
    const ErrorObjectOwnerNotMatch: u64 = 4;
    const ErrorObjectNotShared: u64 = 5;
    ///Can not take out the object which is bound to the account
    const ErrorObjectIsBound: u64 = 6;
    const ErrorObjectAlreadyBorrowed: u64 = 7;
    const ErrorObjectContainsDynamicFields: u64 = 8;

    const SYSTEM_OWNER_ADDRESS: address = @0x0;
    
    const SHARED_OBJECT_FLAG_MASK: u8 = 1;
    const FROZEN_OBJECT_FLAG_MASK: u8 = 1 << 1;
    const BOUND_OBJECT_FLAG_MASK: u8 = 1 << 2;

    const SPARSE_MERKLE_PLACEHOLDER_HASH: address = @0x5350415253455f4d45524b4c455f504c414345484f4c4445525f484153480000;

    struct Root has key{
        // Move VM will auto add a bool field to the empty struct
        // So we manually add a bool field to the struct
        _placeholder: bool,
    }

    /// ObjectEntity<T> is a box of the value of T
    /// It does not have any ability, so it can not be `drop`, `copy`, or `store`, and can only be handled by storage API after creation.
    struct ObjectEntity<T> {
        // The object id
        id: ObjectID,
        // The owner of the object
        owner: address,
        /// A flag to indicate whether the object is shared or frozen
        flag: u8,
        // Table SMT root
        state_root: address,
        // Table size, number of items
        size: u64,

        // The value of the object
        // The value must be the last field
        value: T,
    } 

    /// Object<T> is a pointer to the ObjectEntity<T>, It has `key` and `store` ability. 
    /// It has the same lifetime as the ObjectEntity<T>
    /// Developers only need to use Object<T> related APIs and do not need to know the ObjectEntity<T>.
    struct Object<phantom T> has key, store {
        id: ObjectID,
    }

    #[private_generics(T)]
    /// Create a new Object, Add the Object to the global object storage and return the Object
    public fun new<T: key>(value: T): Object<T> {
        let id = derive_object_id();
        new_with_id(id, value)
    }

    fun derive_object_id(): ObjectID{
        object_id::address_to_object_id(tx_context::fresh_address())
    }

    #[private_generics(T)]
    /// Create a new named Object, the ObjectID is generated by the type_name of `T`
    public fun new_named_object<T: key>(value: T): Object<T> {
        let id = object_id::named_object_id<T>();
        new_with_id(id, value)
    }

    #[private_generics(T)]
    /// Create a new account named object, the ObjectID is generated by the account address and type_name of `T`
    public fun new_account_named_object<T: key>(account: address, value: T): Object<T> {
        let id = object_id::account_named_object_id<T>(account);
        new_with_id(id, value)
    }


    #[private_generics(T)]
    /// Create a new custom object, the ObjectID is generated by the `id` and type_name of `T`
    public fun new_custom_object<ID: drop, T: key>(id: ID, value: T): Object<T> {
        let id = object_id::custom_object_id<ID, T>(id);
        new_with_id(id, value)
    }

    public(friend) fun new_with_id<T: key>(id: ObjectID, value: T): Object<T> {
        let obj_entity = new_internal(id, value);
        add_to_global(obj_entity);
        Object{id}
    }

    fun new_internal<T: key>(id: ObjectID, value: T): ObjectEntity<T> {
        assert!(!contains_global(id), ErrorObjectAlreadyExist);
        let owner = SYSTEM_OWNER_ADDRESS;
        
        ObjectEntity<T>{
            id,
            owner,
            flag: 0u8,
            state_root: SPARSE_MERKLE_PLACEHOLDER_HASH,
            size: 0,
            value,
        }
    }

    /// Borrow the object value
    public fun borrow<T: key>(self: &Object<T>): &T {
        let obj_enitty = borrow_from_global<T>(self.id);
        &obj_enitty.value
    }

    /// Borrow the object mutable value
    public fun borrow_mut<T: key>(self: &mut Object<T>): &mut T {
        let obj_entity = borrow_mut_from_global<T>(self.id);
        &mut obj_entity.value
    }

    /// Check if the object with `object_id` exists in the global object storage
    public fun exists_object(object_id: ObjectID): bool {
        contains_global(object_id)
    }

    /// Check if the object exists in the global object storage and the type of the object is `T`
    public fun exists_object_with_type<T: key>(object_id: ObjectID): bool {
        //TODO check the type of the object
        contains_global(object_id)
    }

    /// Borrow Object from object store by object_id
    /// Any one can borrow an `&Object<T>` from the global object storage
    public fun borrow_object<T: key>(object_id: ObjectID): &Object<T> {
        let object_entity = borrow_from_global<T>(object_id);
        as_ref(object_entity)
    }

    /// Borrow mut Object by `owner` and `object_id`
    public fun borrow_mut_object<T: key>(owner: &signer, object_id: ObjectID): &mut Object<T> {
        let owner_address = signer::address_of(owner);
        let obj = borrow_mut_object_internal<T>(object_id);
        assert!(owner(obj) == owner_address, ErrorObjectOwnerNotMatch);
        obj
    }

    #[private_generics(T)]
    /// Borrow mut Object by `object_id`
    public fun borrow_mut_object_extend<T: key>(object_id: ObjectID): &mut Object<T> {
        let obj = borrow_mut_object_internal<T>(object_id);
        obj
    }

    fun borrow_mut_object_internal<T: key>(object_id: ObjectID): &mut Object<T> {
        let object_entity = borrow_mut_from_global<T>(object_id);
        let obj = as_mut_ref(object_entity);
        obj
    }

    /// Take out the UserOwnedObject by `owner` and `object_id`
    /// The `T` must have `key + store` ability.
    /// Note: When the Object is taken out, the Object will auto become `SystemOwned` Object.
    public fun take_object<T: key + store>(owner: &signer, object_id: ObjectID): Object<T> {
        let owner_address = signer::address_of(owner);
        let object_entity = borrow_mut_from_global<T>(object_id);
        assert!(owner_internal(object_entity) == owner_address, ErrorObjectOwnerNotMatch);
        assert!(!is_bound_internal(object_entity), ErrorObjectIsBound);
        to_system_owned_internal(object_entity);
        mut_entity_as_object(object_entity)
    }

    #[private_generics(T)]
    /// Take out the UserOwnedObject by `object_id`, return the owner and Object
    /// This function is for developer to extend, Only the module of `T` can take out the `UserOwnedObject` with object_id.
    public fun take_object_extend<T: key>(object_id: ObjectID): (address, Object<T>) {
        let object_entity = borrow_mut_from_global<T>(object_id);
        assert!(is_user_owned_internal(object_entity), ErrorObjectOwnerNotMatch);
        assert!(!is_bound_internal(object_entity), ErrorObjectIsBound);
        let owner = owner_internal(object_entity);
        to_system_owned_internal(object_entity);
        (owner, mut_entity_as_object(object_entity))
    }

    // // #[private_generics(T)]
    // TODO Need to tighter restrictions ?
    /// Borrow mut Shared Object by object_id
    public fun borrow_mut_object_shared<T: key>(object_id: ObjectID): &mut Object<T> {
        let obj = borrow_mut_object_internal<T>(object_id);
        assert!(is_shared(obj), ErrorObjectNotShared);
        obj
    }


    #[private_generics(T)]
    /// Remove the object from the global storage, and return the object value
    /// This function is only can be called by the module of `T`.
    /// The caller must ensure that the dynamic fields are empty before delete the Object
    public fun remove<T: key>(self: Object<T>) : T {
        let Object{id} = self; 
        let object_entity = remove_from_global<T>(id);
        let ObjectEntity{id:_, owner:_, flag:_, value, state_root:_, size} = object_entity;
        // Need to ensure that the Table is empty before delete the Object
        assert!(size == 0, ErrorObjectContainsDynamicFields);
        value
    }

    /// Remove the object from the global storage, and return the object value
    /// Do not check if the dynamic fields are empty 
    public(friend) fun remove_unchecked<T: key>(self: Object<T>) : T {
        let Object{id} = self; 
        let object_entity = remove_from_global<T>(id);
        let ObjectEntity{id:_, owner:_, flag:_, value, state_root:_, size:_} = object_entity;
        value
    }

    /// Directly drop the Object
    fun drop<T: key>(self: Object<T>) {
        let Object{id:_} = self;
    }

    /// Make the Object shared, Any one can get the &mut Object<T> from shared object
    /// The shared object also can be removed from the object storage.
    public fun to_shared<T: key>(self: Object<T>) {
        let obj_entity = borrow_mut_from_global<T>(self.id);
        to_shared_internal(obj_entity);
        drop(self);
    }

    fun to_shared_internal<T: key>(self: &mut ObjectEntity<T>) {
        self.flag = self.flag | SHARED_OBJECT_FLAG_MASK;
        to_system_owned_internal(self); 
    }

    public fun is_shared<T: key>(self: &Object<T>) : bool {
        let obj_enitty = borrow_from_global<T>(self.id);
        is_shared_internal(obj_enitty)
    }

    fun is_shared_internal<T>(self: &ObjectEntity<T>) : bool {
        self.flag & SHARED_OBJECT_FLAG_MASK == SHARED_OBJECT_FLAG_MASK
    }

    /// Make the Object frozen, Any one can not get the &mut Object<T> from frozen object
    public fun to_frozen<T: key>(self: Object<T>) {
        let obj_entity = borrow_mut_from_global<T>(self.id);
        to_frozen_internal(obj_entity);
        drop(self);
    }

    fun to_frozen_internal<T: key>(self: &mut ObjectEntity<T>) {
        self.flag = self.flag | FROZEN_OBJECT_FLAG_MASK;
        to_system_owned_internal(self); 
    }

    public fun is_frozen<T:key>(self: &Object<T>) : bool {
        let obj_enitty = borrow_from_global<T>(self.id);
        is_frozen_internal(obj_enitty)
    }

    fun is_frozen_internal<T>(self: &ObjectEntity<T>) : bool {
        self.flag & FROZEN_OBJECT_FLAG_MASK == FROZEN_OBJECT_FLAG_MASK
    }

    //TODO how to provide public bound object API

    fun to_bound_internal<T>(self: &mut ObjectEntity<T>) {
        self.flag = self.flag | BOUND_OBJECT_FLAG_MASK;
    }

    public fun is_bound<T: key>(self: &Object<T>) : bool {
        let obj_enitty = borrow_from_global<T>(self.id);
        is_bound_internal(obj_enitty)
    }
    
    public(friend) fun is_bound_internal<T>(self: &ObjectEntity<T>) : bool {
        self.flag & BOUND_OBJECT_FLAG_MASK == BOUND_OBJECT_FLAG_MASK
    } 

    public(friend) fun to_user_owned<T: key>(self: &mut Object<T>, new_owner: address) {
        assert!(new_owner != SYSTEM_OWNER_ADDRESS, ErrorInvalidOwnerAddress);
        let obj_entity = borrow_mut_from_global<T>(self.id);
        obj_entity.owner = new_owner;
    }

    public(friend) fun to_system_owned<T: key>(self: &mut Object<T>) {
        let obj_entity = borrow_mut_from_global<T>(self.id);
        to_system_owned_internal(obj_entity);
    }

    public(friend) fun to_system_owned_internal<T>(self: &mut ObjectEntity<T>){
        self.owner = SYSTEM_OWNER_ADDRESS;
    }

    /// Transfer the object to the new owner
    /// Only the `T` with `store` can be directly transferred.
    public fun transfer<T: key + store>(self: Object<T>, new_owner: address) {
        to_user_owned(&mut self, new_owner);
        drop(self);
    }

    #[private_generics(T)]
    /// Transfer the object to the new owner
    /// This function is for the module of `T` to extend the `transfer` function.
    public fun transfer_extend<T: key>(self: Object<T>, new_owner: address) {
        to_user_owned(&mut self, new_owner);
        drop(self);
    }

    public fun id<T>(self: &Object<T>): ObjectID {
        self.id
    }

    public fun owner<T: key>(self: &Object<T>): address {
        let obj_enitty = borrow_from_global<T>(self.id);
        obj_enitty.owner
    }

    public(friend) fun owner_internal<T: key>(self: &ObjectEntity<T>): address {
        self.owner
    }

    public fun is_system_owned<T: key>(self: &Object<T>) : bool {
        owner(self) == SYSTEM_OWNER_ADDRESS
    } 
    
    public(friend) fun is_user_owned_internal<T: key>(self: &ObjectEntity<T>) : bool {
        owner_internal(self) != SYSTEM_OWNER_ADDRESS
    }

    public fun is_user_owned<T: key>(self: &Object<T>) : bool {
        owner(self) != SYSTEM_OWNER_ADDRESS
    }

    // === Object Ref ===

    public(friend) fun as_ref<T: key>(object_entity: &ObjectEntity<T>) : &Object<T>{
        as_ref_inner<Object<T>>(object_entity.id)
    }
    public(friend) fun as_mut_ref<T: key>(object_entity: &mut ObjectEntity<T>) : &mut Object<T>{
        as_mut_ref_inner<Object<T>>(object_entity.id)
    }
    public(friend) fun mut_entity_as_object<T: key>(object_entity: &mut ObjectEntity<T>) : Object<T> {
        Object{id: object_entity.id}
    }

    /// Convert the ObjectID to &T or &mut T
    /// The caller must ensure the T only has one `ObjectID` field, such as `Object<T>` or `Table<K,V>`, or `TypeTable`.
    native fun as_ref_inner<T>(object_id: ObjectID): &T;
    native fun as_mut_ref_inner<T>(object_id: ObjectID): &mut T;

    // === Object Storage ===

    const GlobalObjectStorageHandleID: address = @0x0;

    /// The global object storage's table handle should be `0x0`
    public(friend) fun global_object_storage_handle(): ObjectID {
        object_id::address_to_object_id(GlobalObjectStorageHandleID)
    }

    public(friend) fun add_to_global<T: key>(obj: ObjectEntity<T>) {
        add_field_internal<Root, ObjectID, ObjectEntity<T>>(global_object_storage_handle(), obj.id, obj);
    }

    public(friend) fun borrow_root_object(): &ObjectEntity<Root>{
        borrow_from_global<Root>(global_object_storage_handle())
    }

    public(friend) fun borrow_from_global<T: key>(object_id: ObjectID): &ObjectEntity<T> {
        borrow_field_internal<ObjectID, ObjectEntity<T>>(global_object_storage_handle(), object_id)
    }

    public(friend) fun borrow_mut_root_object(): &mut ObjectEntity<Root>{
        borrow_mut_from_global<Root>(global_object_storage_handle())
    }

    public(friend) fun borrow_mut_from_global<T: key>(object_id: ObjectID): &mut ObjectEntity<T> {
        let object_entity = borrow_mut_field_internal<ObjectID, ObjectEntity<T>>(global_object_storage_handle(), object_id);
        assert!(!is_frozen_internal(object_entity), ErrorObjectFrozen);
        object_entity
    }

    public(friend) fun remove_from_global<T: key>(object_id: ObjectID): ObjectEntity<T> {
        remove_field_internal<Root, ObjectID, ObjectEntity<T>>(global_object_storage_handle(), object_id)
    }

    public(friend) fun contains_global(object_id: ObjectID): bool {
        contains_field_internal(global_object_storage_handle(), object_id)
    }


    // === Object Raw Dynamic Table ===

     #[private_generics(T)]
    /// Add a dynamic filed to the object. Aborts if an entry for this
    /// key already exists. The entry itself is not stored in the
    /// table, and cannot be discovered from it.
    public fun add_field<T: key, K: copy + drop, V>(obj: &mut Object<T>, key: K, val: V) {
        add_field_internal<T,K,V>(obj.id, key, val)
    }

     /// Add a new entry to the table. Aborts if an entry for this
    /// key already exists. The entry itself is not stored in the
    /// table, and cannot be discovered from it.
    public(friend) fun add_field_internal<T: key, K: copy + drop, V>(table_handle: ObjectID, key: K, val: V) {
        raw_table::add<K,V>(table_handle, key, val);
        let object_entity = borrow_mut_from_global<T>(table_handle);
        object_entity.size = object_entity.size + 1;
    }

    /// Acquire an immutable reference to the value which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public fun borrow_field<T: key, K: copy + drop, V>(obj: &Object<T>, key: K): &V {
        borrow_field_internal<K, V>(obj.id, key)
    }

     /// Acquire an immutable reference to the value which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public(friend) fun borrow_field_internal<K: copy + drop, V>(table_handle: ObjectID, key: K): &V {
        raw_table::borrow<K, V>(table_handle, key)
    }

    /// Acquire an immutable reference to the value which `key` maps to.
    /// Returns specified default value if there is no entry for `key`.
    public fun borrow_field_with_default<T: key, K: copy + drop, V>(obj: &Object<T>, key: K, default: &V): &V {
        borrow_field_with_default_internal<K, V>(obj.id, key, default)
    }

    /// Acquire an immutable reference to the value which `key` maps to.
    /// Returns specified default value if there is no entry for `key`.
    public(friend) fun borrow_field_with_default_internal<K: copy + drop, V>(table_handle: ObjectID, key: K, default: &V): &V {
         if (!contains_field_internal<K>(table_handle, key)) {
            default
        } else {
            borrow_field_internal(table_handle, key)
        }
    }

    #[private_generics(T)]
    /// Acquire a mutable reference to the value which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public fun borrow_mut_field<T: key, K: copy + drop, V>(obj: &mut Object<T>, key: K): &mut V {
        borrow_mut_field_internal<K, V>(obj.id, key)
    }

    /// Acquire a mutable reference to the value which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public(friend) fun borrow_mut_field_internal<K: copy + drop, V>(table_handle: ObjectID, key: K): &mut V {
        raw_table::borrow_mut<K, V>(table_handle, key)
    }

    #[private_generics(T)]
    /// Acquire a mutable reference to the value which `key` maps to.
    /// Insert the pair (`key`, `default`) first if there is no entry for `key`.
    public fun borrow_mut_field_with_default<T: key, K: copy + drop, V: drop>(obj: &mut Object<T>, key: K, default: V): &mut V {
        borrow_mut_field_with_default_internal<T, K, V>(obj.id, key, default)
    }

    /// Acquire a mutable reference to the value which `key` maps to.
    /// Insert the pair (`key`, `default`) first if there is no entry for `key`.
    public(friend) fun borrow_mut_field_with_default_internal<T: key, K: copy + drop, V: drop>(table_handle: ObjectID, key: K, default: V): &mut V {
        if (!contains_field_internal<K>(table_handle, copy key)) {
            add_field_internal<T, K, V>(table_handle, key, default)
        };
        borrow_mut_field_internal(table_handle, key)
    }

    #[private_generics(T)]
    /// Insert the pair (`key`, `value`) if there is no entry for `key`.
    /// update the value of the entry for `key` to `value` otherwise
    public fun upsert_field<T: key, K: copy + drop, V: drop>(obj: &mut Object<T>, key: K, value: V) {
        upsert_field_internal<T, K, V>(obj.id, key, value)
    }

    /// Insert the pair (`key`, `value`) if there is no entry for `key`.
    /// update the value of the entry for `key` to `value` otherwise
    public(friend) fun upsert_field_internal<T: key, K: copy + drop, V: drop>(table_handle: ObjectID, key: K, value: V) {
        if (!contains_field_internal<K>(table_handle, copy key)) {
            add_field_internal<T, K, V>(table_handle, key, value)
        } else {
            let ref = borrow_mut_field_internal(table_handle, key);
            *ref = value;
        };
    }

    #[private_generics(T)]
    /// Remove from `table` and return the value which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public fun remove_field<T: key, K: copy + drop, V>(obj: &mut Object<T>, key: K): V {
        remove_field_internal<T, K, V>(obj.id, key)
    }

    /// Remove from `table` and return the value which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public(friend) fun remove_field_internal<T: key, K: copy + drop, V>(table_handle: ObjectID, key: K): V {
        let v = raw_table::remove<K, V>(table_handle, key);
        let object_entity = borrow_mut_from_global<T>(table_handle);
        object_entity.size = object_entity.size - 1;
        v
    }

    /// Returns true if `table` contains an entry for `key`.
    public fun contains_field<T: key, K: copy + drop>(obj: &Object<T>, key: K): bool {
        contains_field_internal<K>(obj.id, key)
    }

       /// Returns true if `table` contains an entry for `key`.
    public(friend) fun contains_field_internal<K: copy + drop>(table_handle: ObjectID, key: K): bool {
        raw_table::contains<K>(table_handle, key)
    }

    /// Returns the size of the table, the number of key-value pairs
    public fun field_size<T: key>(obj: &Object<T>): u64 {
        field_size_internal<T>(obj.id)
    }

    public(friend) fun field_size_internal<T: key>(object_id: ObjectID): u64 {
        let object_entity = borrow_from_global<T>(object_id);
        object_entity.size
    }

    #[test_only]
    /// Testing only: allows to drop a Object even if it's fields is not empty.
    public fun drop_unchecked<T: key>(self: Object<T>) : T {
        remove_unchecked(self)
    }

    #[test_only]
    struct TestStruct has key {
        count: u64,
    }

    #[test_only]
    struct TestStruct2 has key {
        count: u64,
    }

    #[test(sender = @0x42)]
    fun test_object(sender: signer) {
        let sender_addr = std::signer::address_of(&sender);
        let init_count = 12;
        let test_struct = TestStruct {
            count: init_count,
        };
        let obj = new<TestStruct>(test_struct);
        assert!(exists_object(obj.id), 1000);
        {
            to_user_owned(&mut obj, sender_addr);
            assert!(owner(&obj) == sender_addr, 1001);
        };
        {
            let test_struct_mut = borrow_mut(&mut obj);
            test_struct_mut.count = test_struct_mut.count + 1;
        };
        {
            let test_struct_ref = borrow(&obj);
            assert!(test_struct_ref.count == init_count + 1, 1002);
        };
        { 
            to_user_owned(&mut obj, @0x10);
            assert!(owner(&obj) != sender_addr, 1003);
        };

        let test_obj = remove(obj);
        let TestStruct{count: _count} = test_obj;
    }

    #[test]
    fun test_shared(){
        let object_id = derive_object_id();
        let obj_enitty = new_internal(object_id, TestStruct { count: 1 });
        assert!(!is_shared_internal(&obj_enitty), 1000);
        assert!(!is_frozen_internal(&obj_enitty), 1001);
        to_shared_internal(&mut obj_enitty);
        assert!(is_shared_internal(&obj_enitty), 1002);
        assert!(!is_frozen_internal(&obj_enitty), 1003);
        add_to_global(obj_enitty);
    }

    #[test]
    fun test_frozen(){
        let object_id = derive_object_id();
        let obj_enitty = new_internal(object_id, TestStruct { count: 1 });
        assert!(!is_shared_internal(&obj_enitty), 1000);
        assert!(!is_frozen_internal(&obj_enitty), 1001);
        to_frozen_internal(&mut obj_enitty);
        assert!(!is_shared_internal(&obj_enitty), 1002);
        assert!(is_frozen_internal(&obj_enitty), 1003);
        add_to_global(obj_enitty);
        
    }

    // An object can not be shared and frozen at the same time
    // This test just ensure the flag can be set at the same time
    #[test]
    fun test_all_flag(){
        let object_id = derive_object_id();
        let obj_enitty = new_internal(object_id, TestStruct { count: 1 });
        assert!(!is_shared_internal(&obj_enitty), 1000);
        assert!(!is_frozen_internal(&obj_enitty), 1001);
        to_shared_internal(&mut obj_enitty);
        to_frozen_internal(&mut obj_enitty);
        assert!(is_shared_internal(&obj_enitty), 1002);
        assert!(is_frozen_internal(&obj_enitty), 1003);
        add_to_global(obj_enitty);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = moveos_std::raw_table)]
    fun test_borrow_not_exist_failure() {
        let obj = new(TestStruct { count: 1 });
        let object_id = obj.id;
        let TestStruct { count : _ } = remove(obj); 
        let _obj_ref = borrow_from_global<TestStruct>(object_id);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = moveos_std::raw_table)]
    fun test_double_remove_failure() {
        
        let object_id = derive_object_id();
        let object = new_with_id(object_id, TestStruct { count: 1 });
        
        let ObjectEntity{ id:_,owner:_,flag:_, value:test_struct1, state_root:_, size:_} = remove_from_global<TestStruct>(object_id);
        let test_struct2 = remove(object);
        let TestStruct { count : _ } = test_struct1;
        let TestStruct { count : _ } = test_struct2;
        
    }

    #[test]
    #[expected_failure(abort_code = 2, location = moveos_std::raw_table)]
    fun test_type_mismatch() {
        
        let object_id = derive_object_id();
        let obj = new_with_id(object_id, TestStruct { count: 1 });
        {
            let test_struct_ref = borrow(&obj);
            assert!(test_struct_ref.count == 1, 1001);
        };
        {
            let test_struct2_object_entity = borrow_from_global<TestStruct2>(object_id);
            assert!(test_struct2_object_entity.value.count == 1, 1002);
        };
        drop(obj);
        
    }

    struct TestStructID has store, copy, drop{
        id: u64,
    }

    #[test]
    fun test_custom_object_id(){
        let id = TestStructID{id: 1};
        let object_id = object_id::custom_object_id<TestStructID, TestStruct>(id);
        //ensure the object_id is the same as the object_id generated by the object.rs
        assert!(object_id::id(&object_id) == @0xaa825038ae811f5c94d20175699d808eae4c624fa85c81faad45de1145284e06, 1);
    }

    #[test]
    fun test_remove_object_success_with_dynamic_fields(){
        let obj = new(TestStruct { count: 1 });
        add_field(&mut obj, 1u64, 1u64);
        let _v:u64 = remove_field(&mut obj, 1u64);
        let s = remove(obj);
        let TestStruct { count : _ } = s;
    }

    #[test]
    #[expected_failure(abort_code = ErrorObjectContainsDynamicFields, location = Self)]
    fun test_remove_object_faild_with_dynamic_fields(){
        let obj = new(TestStruct { count: 1 });
        add_field(&mut obj, 1u64, 1u64);
        let s = remove(obj);
        let TestStruct { count : _ } = s;
    }

    #[test]
    fun test_new(){
        let obj1 = new(TestStruct { count: 1 });
        let obj2 = new(TestStruct { count: 2 });
        assert!(obj1.id != obj2.id, 1);
        let TestStruct { count:_} = drop_unchecked(obj1);
        let TestStruct { count:_} = drop_unchecked(obj2);
    }

    #[test]
    fun test_object_mut(){
        let obj = new(TestStruct{count: 1});
        {
            let obj_value = borrow_mut(&mut obj);
            obj_value.count = 2;
        };
        {
            let obj_value = borrow(&obj);
            assert!(obj_value.count == 2, 1000);
        };
        let TestStruct{count:_} = remove(obj);
    }

    #[test(alice = @0x42)]
    fun test_borrow_object(alice: signer){
        let alice_addr = signer::address_of(&alice);
        
        let obj = new(TestStruct{count: 1});
        let object_id = id(&obj);
        transfer_extend(obj, alice_addr);

        //test borrow_object by id
        {
            let _obj = borrow_object<TestStruct>(object_id);
        };
    }

    #[test(alice = @0x42, bob = @0x43)]
    #[expected_failure(abort_code = 4, location = Self)]
    fun test_borrow_mut_object(alice: &signer, bob: &signer){
        let alice_addr = signer::address_of(alice);
        let obj = new(TestStruct{count: 1});
        let object_id = id(&obj);
        transfer_extend(obj, alice_addr);

        //test borrow_mut_object by owner
        {
            let _obj = borrow_mut_object<TestStruct>(alice, object_id);
        };

        // borrow_mut_object by non-owner failed 
        {
            let _obj = borrow_mut_object<TestStruct>(bob, object_id);
        };
    }

    #[test] 
    fun test_shared_object(){
        let obj = new(TestStruct{count: 1});
        let object_id = id(&obj);
        
        to_shared(obj);
        // any one can borrow_mut the shared object
        {
            let obj = borrow_mut_object_shared<TestStruct>(object_id);
            assert!(is_shared(obj), 1000);
        };
    }


    #[test]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_frozen_object_by_extend(){
        
        let obj = new(TestStruct{count: 1});
        let object_id = id(&obj);
        to_frozen(obj);
        //test borrow_object
        {
            let _obj = borrow_object<TestStruct>(object_id);
        };

        // none one can borrow_mut from the frozen object
        {
            let _obj = borrow_mut_object_extend<TestStruct>(object_id);
        };
    }
}
