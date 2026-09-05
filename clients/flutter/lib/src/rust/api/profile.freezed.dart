// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'profile.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$CommandError {

 String get reason;
/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CommandErrorCopyWith<CommandError> get copyWith => _$CommandErrorCopyWithImpl<CommandError>(this as CommandError, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CommandError&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,reason);

@override
String toString() {
  return 'CommandError(reason: $reason)';
}


}

/// @nodoc
abstract mixin class $CommandErrorCopyWith<$Res>  {
  factory $CommandErrorCopyWith(CommandError value, $Res Function(CommandError) _then) = _$CommandErrorCopyWithImpl;
@useResult
$Res call({
 String reason
});




}
/// @nodoc
class _$CommandErrorCopyWithImpl<$Res>
    implements $CommandErrorCopyWith<$Res> {
  _$CommandErrorCopyWithImpl(this._self, this._then);

  final CommandError _self;
  final $Res Function(CommandError) _then;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? reason = null,}) {
  return _then(_self.copyWith(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [CommandError].
extension CommandErrorPatterns on CommandError {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( CommandError_Transport value)?  transport,TResult Function( CommandError_Storage value)?  storage,TResult Function( CommandError_Protocol value)?  protocol,TResult Function( CommandError_Domain value)?  domain,TResult Function( CommandError_FileSystem value)?  fileSystem,TResult Function( CommandError_Internal value)?  internal,TResult Function( CommandError_Interrupted value)?  interrupted,required TResult orElse(),}){
final _that = this;
switch (_that) {
case CommandError_Transport() when transport != null:
return transport(_that);case CommandError_Storage() when storage != null:
return storage(_that);case CommandError_Protocol() when protocol != null:
return protocol(_that);case CommandError_Domain() when domain != null:
return domain(_that);case CommandError_FileSystem() when fileSystem != null:
return fileSystem(_that);case CommandError_Internal() when internal != null:
return internal(_that);case CommandError_Interrupted() when interrupted != null:
return interrupted(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( CommandError_Transport value)  transport,required TResult Function( CommandError_Storage value)  storage,required TResult Function( CommandError_Protocol value)  protocol,required TResult Function( CommandError_Domain value)  domain,required TResult Function( CommandError_FileSystem value)  fileSystem,required TResult Function( CommandError_Internal value)  internal,required TResult Function( CommandError_Interrupted value)  interrupted,}){
final _that = this;
switch (_that) {
case CommandError_Transport():
return transport(_that);case CommandError_Storage():
return storage(_that);case CommandError_Protocol():
return protocol(_that);case CommandError_Domain():
return domain(_that);case CommandError_FileSystem():
return fileSystem(_that);case CommandError_Internal():
return internal(_that);case CommandError_Interrupted():
return interrupted(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( CommandError_Transport value)?  transport,TResult? Function( CommandError_Storage value)?  storage,TResult? Function( CommandError_Protocol value)?  protocol,TResult? Function( CommandError_Domain value)?  domain,TResult? Function( CommandError_FileSystem value)?  fileSystem,TResult? Function( CommandError_Internal value)?  internal,TResult? Function( CommandError_Interrupted value)?  interrupted,}){
final _that = this;
switch (_that) {
case CommandError_Transport() when transport != null:
return transport(_that);case CommandError_Storage() when storage != null:
return storage(_that);case CommandError_Protocol() when protocol != null:
return protocol(_that);case CommandError_Domain() when domain != null:
return domain(_that);case CommandError_FileSystem() when fileSystem != null:
return fileSystem(_that);case CommandError_Internal() when internal != null:
return internal(_that);case CommandError_Interrupted() when interrupted != null:
return interrupted(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String operation,  String reason)?  transport,TResult Function( String operation,  String reason)?  storage,TResult Function( String operation,  String reason)?  protocol,TResult Function( String operation,  String reason)?  domain,TResult Function( String operation,  String reason)?  fileSystem,TResult Function( String operation,  String reason)?  internal,TResult Function( String reason)?  interrupted,required TResult orElse(),}) {final _that = this;
switch (_that) {
case CommandError_Transport() when transport != null:
return transport(_that.operation,_that.reason);case CommandError_Storage() when storage != null:
return storage(_that.operation,_that.reason);case CommandError_Protocol() when protocol != null:
return protocol(_that.operation,_that.reason);case CommandError_Domain() when domain != null:
return domain(_that.operation,_that.reason);case CommandError_FileSystem() when fileSystem != null:
return fileSystem(_that.operation,_that.reason);case CommandError_Internal() when internal != null:
return internal(_that.operation,_that.reason);case CommandError_Interrupted() when interrupted != null:
return interrupted(_that.reason);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String operation,  String reason)  transport,required TResult Function( String operation,  String reason)  storage,required TResult Function( String operation,  String reason)  protocol,required TResult Function( String operation,  String reason)  domain,required TResult Function( String operation,  String reason)  fileSystem,required TResult Function( String operation,  String reason)  internal,required TResult Function( String reason)  interrupted,}) {final _that = this;
switch (_that) {
case CommandError_Transport():
return transport(_that.operation,_that.reason);case CommandError_Storage():
return storage(_that.operation,_that.reason);case CommandError_Protocol():
return protocol(_that.operation,_that.reason);case CommandError_Domain():
return domain(_that.operation,_that.reason);case CommandError_FileSystem():
return fileSystem(_that.operation,_that.reason);case CommandError_Internal():
return internal(_that.operation,_that.reason);case CommandError_Interrupted():
return interrupted(_that.reason);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String operation,  String reason)?  transport,TResult? Function( String operation,  String reason)?  storage,TResult? Function( String operation,  String reason)?  protocol,TResult? Function( String operation,  String reason)?  domain,TResult? Function( String operation,  String reason)?  fileSystem,TResult? Function( String operation,  String reason)?  internal,TResult? Function( String reason)?  interrupted,}) {final _that = this;
switch (_that) {
case CommandError_Transport() when transport != null:
return transport(_that.operation,_that.reason);case CommandError_Storage() when storage != null:
return storage(_that.operation,_that.reason);case CommandError_Protocol() when protocol != null:
return protocol(_that.operation,_that.reason);case CommandError_Domain() when domain != null:
return domain(_that.operation,_that.reason);case CommandError_FileSystem() when fileSystem != null:
return fileSystem(_that.operation,_that.reason);case CommandError_Internal() when internal != null:
return internal(_that.operation,_that.reason);case CommandError_Interrupted() when interrupted != null:
return interrupted(_that.reason);case _:
  return null;

}
}

}

/// @nodoc


class CommandError_Transport extends CommandError {
  const CommandError_Transport({required this.operation, required this.reason}): super._();
  

 final  String operation;
@override final  String reason;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CommandError_TransportCopyWith<CommandError_Transport> get copyWith => _$CommandError_TransportCopyWithImpl<CommandError_Transport>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CommandError_Transport&&(identical(other.operation, operation) || other.operation == operation)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,operation,reason);

@override
String toString() {
  return 'CommandError.transport(operation: $operation, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $CommandError_TransportCopyWith<$Res> implements $CommandErrorCopyWith<$Res> {
  factory $CommandError_TransportCopyWith(CommandError_Transport value, $Res Function(CommandError_Transport) _then) = _$CommandError_TransportCopyWithImpl;
@override @useResult
$Res call({
 String operation, String reason
});




}
/// @nodoc
class _$CommandError_TransportCopyWithImpl<$Res>
    implements $CommandError_TransportCopyWith<$Res> {
  _$CommandError_TransportCopyWithImpl(this._self, this._then);

  final CommandError_Transport _self;
  final $Res Function(CommandError_Transport) _then;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? operation = null,Object? reason = null,}) {
  return _then(CommandError_Transport(
operation: null == operation ? _self.operation : operation // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class CommandError_Storage extends CommandError {
  const CommandError_Storage({required this.operation, required this.reason}): super._();
  

 final  String operation;
@override final  String reason;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CommandError_StorageCopyWith<CommandError_Storage> get copyWith => _$CommandError_StorageCopyWithImpl<CommandError_Storage>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CommandError_Storage&&(identical(other.operation, operation) || other.operation == operation)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,operation,reason);

@override
String toString() {
  return 'CommandError.storage(operation: $operation, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $CommandError_StorageCopyWith<$Res> implements $CommandErrorCopyWith<$Res> {
  factory $CommandError_StorageCopyWith(CommandError_Storage value, $Res Function(CommandError_Storage) _then) = _$CommandError_StorageCopyWithImpl;
@override @useResult
$Res call({
 String operation, String reason
});




}
/// @nodoc
class _$CommandError_StorageCopyWithImpl<$Res>
    implements $CommandError_StorageCopyWith<$Res> {
  _$CommandError_StorageCopyWithImpl(this._self, this._then);

  final CommandError_Storage _self;
  final $Res Function(CommandError_Storage) _then;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? operation = null,Object? reason = null,}) {
  return _then(CommandError_Storage(
operation: null == operation ? _self.operation : operation // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class CommandError_Protocol extends CommandError {
  const CommandError_Protocol({required this.operation, required this.reason}): super._();
  

 final  String operation;
@override final  String reason;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CommandError_ProtocolCopyWith<CommandError_Protocol> get copyWith => _$CommandError_ProtocolCopyWithImpl<CommandError_Protocol>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CommandError_Protocol&&(identical(other.operation, operation) || other.operation == operation)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,operation,reason);

@override
String toString() {
  return 'CommandError.protocol(operation: $operation, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $CommandError_ProtocolCopyWith<$Res> implements $CommandErrorCopyWith<$Res> {
  factory $CommandError_ProtocolCopyWith(CommandError_Protocol value, $Res Function(CommandError_Protocol) _then) = _$CommandError_ProtocolCopyWithImpl;
@override @useResult
$Res call({
 String operation, String reason
});




}
/// @nodoc
class _$CommandError_ProtocolCopyWithImpl<$Res>
    implements $CommandError_ProtocolCopyWith<$Res> {
  _$CommandError_ProtocolCopyWithImpl(this._self, this._then);

  final CommandError_Protocol _self;
  final $Res Function(CommandError_Protocol) _then;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? operation = null,Object? reason = null,}) {
  return _then(CommandError_Protocol(
operation: null == operation ? _self.operation : operation // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class CommandError_Domain extends CommandError {
  const CommandError_Domain({required this.operation, required this.reason}): super._();
  

 final  String operation;
@override final  String reason;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CommandError_DomainCopyWith<CommandError_Domain> get copyWith => _$CommandError_DomainCopyWithImpl<CommandError_Domain>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CommandError_Domain&&(identical(other.operation, operation) || other.operation == operation)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,operation,reason);

@override
String toString() {
  return 'CommandError.domain(operation: $operation, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $CommandError_DomainCopyWith<$Res> implements $CommandErrorCopyWith<$Res> {
  factory $CommandError_DomainCopyWith(CommandError_Domain value, $Res Function(CommandError_Domain) _then) = _$CommandError_DomainCopyWithImpl;
@override @useResult
$Res call({
 String operation, String reason
});




}
/// @nodoc
class _$CommandError_DomainCopyWithImpl<$Res>
    implements $CommandError_DomainCopyWith<$Res> {
  _$CommandError_DomainCopyWithImpl(this._self, this._then);

  final CommandError_Domain _self;
  final $Res Function(CommandError_Domain) _then;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? operation = null,Object? reason = null,}) {
  return _then(CommandError_Domain(
operation: null == operation ? _self.operation : operation // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class CommandError_FileSystem extends CommandError {
  const CommandError_FileSystem({required this.operation, required this.reason}): super._();
  

 final  String operation;
@override final  String reason;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CommandError_FileSystemCopyWith<CommandError_FileSystem> get copyWith => _$CommandError_FileSystemCopyWithImpl<CommandError_FileSystem>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CommandError_FileSystem&&(identical(other.operation, operation) || other.operation == operation)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,operation,reason);

@override
String toString() {
  return 'CommandError.fileSystem(operation: $operation, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $CommandError_FileSystemCopyWith<$Res> implements $CommandErrorCopyWith<$Res> {
  factory $CommandError_FileSystemCopyWith(CommandError_FileSystem value, $Res Function(CommandError_FileSystem) _then) = _$CommandError_FileSystemCopyWithImpl;
@override @useResult
$Res call({
 String operation, String reason
});




}
/// @nodoc
class _$CommandError_FileSystemCopyWithImpl<$Res>
    implements $CommandError_FileSystemCopyWith<$Res> {
  _$CommandError_FileSystemCopyWithImpl(this._self, this._then);

  final CommandError_FileSystem _self;
  final $Res Function(CommandError_FileSystem) _then;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? operation = null,Object? reason = null,}) {
  return _then(CommandError_FileSystem(
operation: null == operation ? _self.operation : operation // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class CommandError_Internal extends CommandError {
  const CommandError_Internal({required this.operation, required this.reason}): super._();
  

 final  String operation;
@override final  String reason;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CommandError_InternalCopyWith<CommandError_Internal> get copyWith => _$CommandError_InternalCopyWithImpl<CommandError_Internal>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CommandError_Internal&&(identical(other.operation, operation) || other.operation == operation)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,operation,reason);

@override
String toString() {
  return 'CommandError.internal(operation: $operation, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $CommandError_InternalCopyWith<$Res> implements $CommandErrorCopyWith<$Res> {
  factory $CommandError_InternalCopyWith(CommandError_Internal value, $Res Function(CommandError_Internal) _then) = _$CommandError_InternalCopyWithImpl;
@override @useResult
$Res call({
 String operation, String reason
});




}
/// @nodoc
class _$CommandError_InternalCopyWithImpl<$Res>
    implements $CommandError_InternalCopyWith<$Res> {
  _$CommandError_InternalCopyWithImpl(this._self, this._then);

  final CommandError_Internal _self;
  final $Res Function(CommandError_Internal) _then;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? operation = null,Object? reason = null,}) {
  return _then(CommandError_Internal(
operation: null == operation ? _self.operation : operation // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class CommandError_Interrupted extends CommandError {
  const CommandError_Interrupted({required this.reason}): super._();
  

@override final  String reason;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CommandError_InterruptedCopyWith<CommandError_Interrupted> get copyWith => _$CommandError_InterruptedCopyWithImpl<CommandError_Interrupted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CommandError_Interrupted&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,reason);

@override
String toString() {
  return 'CommandError.interrupted(reason: $reason)';
}


}

/// @nodoc
abstract mixin class $CommandError_InterruptedCopyWith<$Res> implements $CommandErrorCopyWith<$Res> {
  factory $CommandError_InterruptedCopyWith(CommandError_Interrupted value, $Res Function(CommandError_Interrupted) _then) = _$CommandError_InterruptedCopyWithImpl;
@override @useResult
$Res call({
 String reason
});




}
/// @nodoc
class _$CommandError_InterruptedCopyWithImpl<$Res>
    implements $CommandError_InterruptedCopyWith<$Res> {
  _$CommandError_InterruptedCopyWithImpl(this._self, this._then);

  final CommandError_Interrupted _self;
  final $Res Function(CommandError_Interrupted) _then;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? reason = null,}) {
  return _then(CommandError_Interrupted(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$ProfileError {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProfileError);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ProfileError()';
}


}

/// @nodoc
class $ProfileErrorCopyWith<$Res>  {
$ProfileErrorCopyWith(ProfileError _, $Res Function(ProfileError) __);
}


/// Adds pattern-matching-related methods to [ProfileError].
extension ProfileErrorPatterns on ProfileError {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( ProfileError_BadKey value)?  badKey,TResult Function( ProfileError_AlreadyOpen value)?  alreadyOpen,TResult Function( ProfileError_Closing value)?  closing,TResult Function( ProfileError_InUse value)?  inUse,TResult Function( ProfileError_Unusable value)?  unusable,TResult Function( ProfileError_Io value)?  io,required TResult orElse(),}){
final _that = this;
switch (_that) {
case ProfileError_BadKey() when badKey != null:
return badKey(_that);case ProfileError_AlreadyOpen() when alreadyOpen != null:
return alreadyOpen(_that);case ProfileError_Closing() when closing != null:
return closing(_that);case ProfileError_InUse() when inUse != null:
return inUse(_that);case ProfileError_Unusable() when unusable != null:
return unusable(_that);case ProfileError_Io() when io != null:
return io(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( ProfileError_BadKey value)  badKey,required TResult Function( ProfileError_AlreadyOpen value)  alreadyOpen,required TResult Function( ProfileError_Closing value)  closing,required TResult Function( ProfileError_InUse value)  inUse,required TResult Function( ProfileError_Unusable value)  unusable,required TResult Function( ProfileError_Io value)  io,}){
final _that = this;
switch (_that) {
case ProfileError_BadKey():
return badKey(_that);case ProfileError_AlreadyOpen():
return alreadyOpen(_that);case ProfileError_Closing():
return closing(_that);case ProfileError_InUse():
return inUse(_that);case ProfileError_Unusable():
return unusable(_that);case ProfileError_Io():
return io(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( ProfileError_BadKey value)?  badKey,TResult? Function( ProfileError_AlreadyOpen value)?  alreadyOpen,TResult? Function( ProfileError_Closing value)?  closing,TResult? Function( ProfileError_InUse value)?  inUse,TResult? Function( ProfileError_Unusable value)?  unusable,TResult? Function( ProfileError_Io value)?  io,}){
final _that = this;
switch (_that) {
case ProfileError_BadKey() when badKey != null:
return badKey(_that);case ProfileError_AlreadyOpen() when alreadyOpen != null:
return alreadyOpen(_that);case ProfileError_Closing() when closing != null:
return closing(_that);case ProfileError_InUse() when inUse != null:
return inUse(_that);case ProfileError_Unusable() when unusable != null:
return unusable(_that);case ProfileError_Io() when io != null:
return io(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  badKey,TResult Function( String path)?  alreadyOpen,TResult Function( String path)?  closing,TResult Function( String path)?  inUse,TResult Function( String path,  String reason)?  unusable,TResult Function( String path,  String reason)?  io,required TResult orElse(),}) {final _that = this;
switch (_that) {
case ProfileError_BadKey() when badKey != null:
return badKey();case ProfileError_AlreadyOpen() when alreadyOpen != null:
return alreadyOpen(_that.path);case ProfileError_Closing() when closing != null:
return closing(_that.path);case ProfileError_InUse() when inUse != null:
return inUse(_that.path);case ProfileError_Unusable() when unusable != null:
return unusable(_that.path,_that.reason);case ProfileError_Io() when io != null:
return io(_that.path,_that.reason);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  badKey,required TResult Function( String path)  alreadyOpen,required TResult Function( String path)  closing,required TResult Function( String path)  inUse,required TResult Function( String path,  String reason)  unusable,required TResult Function( String path,  String reason)  io,}) {final _that = this;
switch (_that) {
case ProfileError_BadKey():
return badKey();case ProfileError_AlreadyOpen():
return alreadyOpen(_that.path);case ProfileError_Closing():
return closing(_that.path);case ProfileError_InUse():
return inUse(_that.path);case ProfileError_Unusable():
return unusable(_that.path,_that.reason);case ProfileError_Io():
return io(_that.path,_that.reason);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  badKey,TResult? Function( String path)?  alreadyOpen,TResult? Function( String path)?  closing,TResult? Function( String path)?  inUse,TResult? Function( String path,  String reason)?  unusable,TResult? Function( String path,  String reason)?  io,}) {final _that = this;
switch (_that) {
case ProfileError_BadKey() when badKey != null:
return badKey();case ProfileError_AlreadyOpen() when alreadyOpen != null:
return alreadyOpen(_that.path);case ProfileError_Closing() when closing != null:
return closing(_that.path);case ProfileError_InUse() when inUse != null:
return inUse(_that.path);case ProfileError_Unusable() when unusable != null:
return unusable(_that.path,_that.reason);case ProfileError_Io() when io != null:
return io(_that.path,_that.reason);case _:
  return null;

}
}

}

/// @nodoc


class ProfileError_BadKey extends ProfileError {
  const ProfileError_BadKey(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProfileError_BadKey);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ProfileError.badKey()';
}


}




/// @nodoc


class ProfileError_AlreadyOpen extends ProfileError {
  const ProfileError_AlreadyOpen({required this.path}): super._();
  

 final  String path;

/// Create a copy of ProfileError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProfileError_AlreadyOpenCopyWith<ProfileError_AlreadyOpen> get copyWith => _$ProfileError_AlreadyOpenCopyWithImpl<ProfileError_AlreadyOpen>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProfileError_AlreadyOpen&&(identical(other.path, path) || other.path == path));
}


@override
int get hashCode => Object.hash(runtimeType,path);

@override
String toString() {
  return 'ProfileError.alreadyOpen(path: $path)';
}


}

/// @nodoc
abstract mixin class $ProfileError_AlreadyOpenCopyWith<$Res> implements $ProfileErrorCopyWith<$Res> {
  factory $ProfileError_AlreadyOpenCopyWith(ProfileError_AlreadyOpen value, $Res Function(ProfileError_AlreadyOpen) _then) = _$ProfileError_AlreadyOpenCopyWithImpl;
@useResult
$Res call({
 String path
});




}
/// @nodoc
class _$ProfileError_AlreadyOpenCopyWithImpl<$Res>
    implements $ProfileError_AlreadyOpenCopyWith<$Res> {
  _$ProfileError_AlreadyOpenCopyWithImpl(this._self, this._then);

  final ProfileError_AlreadyOpen _self;
  final $Res Function(ProfileError_AlreadyOpen) _then;

/// Create a copy of ProfileError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? path = null,}) {
  return _then(ProfileError_AlreadyOpen(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ProfileError_Closing extends ProfileError {
  const ProfileError_Closing({required this.path}): super._();
  

 final  String path;

/// Create a copy of ProfileError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProfileError_ClosingCopyWith<ProfileError_Closing> get copyWith => _$ProfileError_ClosingCopyWithImpl<ProfileError_Closing>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProfileError_Closing&&(identical(other.path, path) || other.path == path));
}


@override
int get hashCode => Object.hash(runtimeType,path);

@override
String toString() {
  return 'ProfileError.closing(path: $path)';
}


}

/// @nodoc
abstract mixin class $ProfileError_ClosingCopyWith<$Res> implements $ProfileErrorCopyWith<$Res> {
  factory $ProfileError_ClosingCopyWith(ProfileError_Closing value, $Res Function(ProfileError_Closing) _then) = _$ProfileError_ClosingCopyWithImpl;
@useResult
$Res call({
 String path
});




}
/// @nodoc
class _$ProfileError_ClosingCopyWithImpl<$Res>
    implements $ProfileError_ClosingCopyWith<$Res> {
  _$ProfileError_ClosingCopyWithImpl(this._self, this._then);

  final ProfileError_Closing _self;
  final $Res Function(ProfileError_Closing) _then;

/// Create a copy of ProfileError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? path = null,}) {
  return _then(ProfileError_Closing(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ProfileError_InUse extends ProfileError {
  const ProfileError_InUse({required this.path}): super._();
  

 final  String path;

/// Create a copy of ProfileError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProfileError_InUseCopyWith<ProfileError_InUse> get copyWith => _$ProfileError_InUseCopyWithImpl<ProfileError_InUse>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProfileError_InUse&&(identical(other.path, path) || other.path == path));
}


@override
int get hashCode => Object.hash(runtimeType,path);

@override
String toString() {
  return 'ProfileError.inUse(path: $path)';
}


}

/// @nodoc
abstract mixin class $ProfileError_InUseCopyWith<$Res> implements $ProfileErrorCopyWith<$Res> {
  factory $ProfileError_InUseCopyWith(ProfileError_InUse value, $Res Function(ProfileError_InUse) _then) = _$ProfileError_InUseCopyWithImpl;
@useResult
$Res call({
 String path
});




}
/// @nodoc
class _$ProfileError_InUseCopyWithImpl<$Res>
    implements $ProfileError_InUseCopyWith<$Res> {
  _$ProfileError_InUseCopyWithImpl(this._self, this._then);

  final ProfileError_InUse _self;
  final $Res Function(ProfileError_InUse) _then;

/// Create a copy of ProfileError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? path = null,}) {
  return _then(ProfileError_InUse(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ProfileError_Unusable extends ProfileError {
  const ProfileError_Unusable({required this.path, required this.reason}): super._();
  

 final  String path;
 final  String reason;

/// Create a copy of ProfileError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProfileError_UnusableCopyWith<ProfileError_Unusable> get copyWith => _$ProfileError_UnusableCopyWithImpl<ProfileError_Unusable>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProfileError_Unusable&&(identical(other.path, path) || other.path == path)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,path,reason);

@override
String toString() {
  return 'ProfileError.unusable(path: $path, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $ProfileError_UnusableCopyWith<$Res> implements $ProfileErrorCopyWith<$Res> {
  factory $ProfileError_UnusableCopyWith(ProfileError_Unusable value, $Res Function(ProfileError_Unusable) _then) = _$ProfileError_UnusableCopyWithImpl;
@useResult
$Res call({
 String path, String reason
});




}
/// @nodoc
class _$ProfileError_UnusableCopyWithImpl<$Res>
    implements $ProfileError_UnusableCopyWith<$Res> {
  _$ProfileError_UnusableCopyWithImpl(this._self, this._then);

  final ProfileError_Unusable _self;
  final $Res Function(ProfileError_Unusable) _then;

/// Create a copy of ProfileError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? path = null,Object? reason = null,}) {
  return _then(ProfileError_Unusable(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ProfileError_Io extends ProfileError {
  const ProfileError_Io({required this.path, required this.reason}): super._();
  

 final  String path;
 final  String reason;

/// Create a copy of ProfileError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProfileError_IoCopyWith<ProfileError_Io> get copyWith => _$ProfileError_IoCopyWithImpl<ProfileError_Io>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProfileError_Io&&(identical(other.path, path) || other.path == path)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,path,reason);

@override
String toString() {
  return 'ProfileError.io(path: $path, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $ProfileError_IoCopyWith<$Res> implements $ProfileErrorCopyWith<$Res> {
  factory $ProfileError_IoCopyWith(ProfileError_Io value, $Res Function(ProfileError_Io) _then) = _$ProfileError_IoCopyWithImpl;
@useResult
$Res call({
 String path, String reason
});




}
/// @nodoc
class _$ProfileError_IoCopyWithImpl<$Res>
    implements $ProfileError_IoCopyWith<$Res> {
  _$ProfileError_IoCopyWithImpl(this._self, this._then);

  final ProfileError_Io _self;
  final $Res Function(ProfileError_Io) _then;

/// Create a copy of ProfileError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? path = null,Object? reason = null,}) {
  return _then(ProfileError_Io(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
