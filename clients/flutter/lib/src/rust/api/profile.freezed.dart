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





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CommandError);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'CommandError()';
}


}

/// @nodoc
class $CommandErrorCopyWith<$Res>  {
$CommandErrorCopyWith(CommandError _, $Res Function(CommandError) __);
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( CommandError_Busy value)?  busy,TResult Function( CommandError_Transport value)?  transport,TResult Function( CommandError_Storage value)?  storage,TResult Function( CommandError_Protocol value)?  protocol,TResult Function( CommandError_Domain value)?  domain,TResult Function( CommandError_FileSystem value)?  fileSystem,TResult Function( CommandError_Internal value)?  internal,TResult Function( CommandError_Interrupted value)?  interrupted,required TResult orElse(),}){
final _that = this;
switch (_that) {
case CommandError_Busy() when busy != null:
return busy(_that);case CommandError_Transport() when transport != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( CommandError_Busy value)  busy,required TResult Function( CommandError_Transport value)  transport,required TResult Function( CommandError_Storage value)  storage,required TResult Function( CommandError_Protocol value)  protocol,required TResult Function( CommandError_Domain value)  domain,required TResult Function( CommandError_FileSystem value)  fileSystem,required TResult Function( CommandError_Internal value)  internal,required TResult Function( CommandError_Interrupted value)  interrupted,}){
final _that = this;
switch (_that) {
case CommandError_Busy():
return busy(_that);case CommandError_Transport():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( CommandError_Busy value)?  busy,TResult? Function( CommandError_Transport value)?  transport,TResult? Function( CommandError_Storage value)?  storage,TResult? Function( CommandError_Protocol value)?  protocol,TResult? Function( CommandError_Domain value)?  domain,TResult? Function( CommandError_FileSystem value)?  fileSystem,TResult? Function( CommandError_Internal value)?  internal,TResult? Function( CommandError_Interrupted value)?  interrupted,}){
final _that = this;
switch (_that) {
case CommandError_Busy() when busy != null:
return busy(_that);case CommandError_Transport() when transport != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String operation,  int active)?  busy,TResult Function( String operation,  String reason)?  transport,TResult Function( String operation,  String reason)?  storage,TResult Function( String operation,  String reason)?  protocol,TResult Function( String operation,  String reason)?  domain,TResult Function( String operation,  String reason)?  fileSystem,TResult Function( String operation,  String reason)?  internal,TResult Function( String reason)?  interrupted,required TResult orElse(),}) {final _that = this;
switch (_that) {
case CommandError_Busy() when busy != null:
return busy(_that.operation,_that.active);case CommandError_Transport() when transport != null:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String operation,  int active)  busy,required TResult Function( String operation,  String reason)  transport,required TResult Function( String operation,  String reason)  storage,required TResult Function( String operation,  String reason)  protocol,required TResult Function( String operation,  String reason)  domain,required TResult Function( String operation,  String reason)  fileSystem,required TResult Function( String operation,  String reason)  internal,required TResult Function( String reason)  interrupted,}) {final _that = this;
switch (_that) {
case CommandError_Busy():
return busy(_that.operation,_that.active);case CommandError_Transport():
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String operation,  int active)?  busy,TResult? Function( String operation,  String reason)?  transport,TResult? Function( String operation,  String reason)?  storage,TResult? Function( String operation,  String reason)?  protocol,TResult? Function( String operation,  String reason)?  domain,TResult? Function( String operation,  String reason)?  fileSystem,TResult? Function( String operation,  String reason)?  internal,TResult? Function( String reason)?  interrupted,}) {final _that = this;
switch (_that) {
case CommandError_Busy() when busy != null:
return busy(_that.operation,_that.active);case CommandError_Transport() when transport != null:
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


class CommandError_Busy extends CommandError {
  const CommandError_Busy({required this.operation, required this.active}): super._();
  

 final  String operation;
 final  int active;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CommandError_BusyCopyWith<CommandError_Busy> get copyWith => _$CommandError_BusyCopyWithImpl<CommandError_Busy>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CommandError_Busy&&(identical(other.operation, operation) || other.operation == operation)&&(identical(other.active, active) || other.active == active));
}


@override
int get hashCode => Object.hash(runtimeType,operation,active);

@override
String toString() {
  return 'CommandError.busy(operation: $operation, active: $active)';
}


}

/// @nodoc
abstract mixin class $CommandError_BusyCopyWith<$Res> implements $CommandErrorCopyWith<$Res> {
  factory $CommandError_BusyCopyWith(CommandError_Busy value, $Res Function(CommandError_Busy) _then) = _$CommandError_BusyCopyWithImpl;
@useResult
$Res call({
 String operation, int active
});




}
/// @nodoc
class _$CommandError_BusyCopyWithImpl<$Res>
    implements $CommandError_BusyCopyWith<$Res> {
  _$CommandError_BusyCopyWithImpl(this._self, this._then);

  final CommandError_Busy _self;
  final $Res Function(CommandError_Busy) _then;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? operation = null,Object? active = null,}) {
  return _then(CommandError_Busy(
operation: null == operation ? _self.operation : operation // ignore: cast_nullable_to_non_nullable
as String,active: null == active ? _self.active : active // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class CommandError_Transport extends CommandError {
  const CommandError_Transport({required this.operation, required this.reason}): super._();
  

 final  String operation;
 final  String reason;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
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
@useResult
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
@pragma('vm:prefer-inline') $Res call({Object? operation = null,Object? reason = null,}) {
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
 final  String reason;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
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
@useResult
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
@pragma('vm:prefer-inline') $Res call({Object? operation = null,Object? reason = null,}) {
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
 final  String reason;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
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
@useResult
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
@pragma('vm:prefer-inline') $Res call({Object? operation = null,Object? reason = null,}) {
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
 final  String reason;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
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
@useResult
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
@pragma('vm:prefer-inline') $Res call({Object? operation = null,Object? reason = null,}) {
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
 final  String reason;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
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
@useResult
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
@pragma('vm:prefer-inline') $Res call({Object? operation = null,Object? reason = null,}) {
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
 final  String reason;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
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
@useResult
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
@pragma('vm:prefer-inline') $Res call({Object? operation = null,Object? reason = null,}) {
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
  

 final  String reason;

/// Create a copy of CommandError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
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
@useResult
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
@pragma('vm:prefer-inline') $Res call({Object? reason = null,}) {
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

/// @nodoc
mixin _$ProgressKindView {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProgressKindView);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ProgressKindView()';
}


}

/// @nodoc
class $ProgressKindViewCopyWith<$Res>  {
$ProgressKindViewCopyWith(ProgressKindView _, $Res Function(ProgressKindView) __);
}


/// Adds pattern-matching-related methods to [ProgressKindView].
extension ProgressKindViewPatterns on ProgressKindView {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( ProgressKindView_MessageQueued value)?  messageQueued,TResult Function( ProgressKindView_MessageReceived value)?  messageReceived,TResult Function( ProgressKindView_EnvelopesPublished value)?  envelopesPublished,TResult Function( ProgressKindView_DeliveryChanged value)?  deliveryChanged,TResult Function( ProgressKindView_FileAnnounced value)?  fileAnnounced,TResult Function( ProgressKindView_FileTransfer value)?  fileTransfer,TResult Function( ProgressKindView_FileSaved value)?  fileSaved,TResult Function( ProgressKindView_Synced value)?  synced,TResult Function( ProgressKindView_PairingChanged value)?  pairingChanged,TResult Function( ProgressKindView_RelayUnavailable value)?  relayUnavailable,TResult Function( ProgressKindView_Onboarding value)?  onboarding,TResult Function( ProgressKindView_Gap value)?  gap,required TResult orElse(),}){
final _that = this;
switch (_that) {
case ProgressKindView_MessageQueued() when messageQueued != null:
return messageQueued(_that);case ProgressKindView_MessageReceived() when messageReceived != null:
return messageReceived(_that);case ProgressKindView_EnvelopesPublished() when envelopesPublished != null:
return envelopesPublished(_that);case ProgressKindView_DeliveryChanged() when deliveryChanged != null:
return deliveryChanged(_that);case ProgressKindView_FileAnnounced() when fileAnnounced != null:
return fileAnnounced(_that);case ProgressKindView_FileTransfer() when fileTransfer != null:
return fileTransfer(_that);case ProgressKindView_FileSaved() when fileSaved != null:
return fileSaved(_that);case ProgressKindView_Synced() when synced != null:
return synced(_that);case ProgressKindView_PairingChanged() when pairingChanged != null:
return pairingChanged(_that);case ProgressKindView_RelayUnavailable() when relayUnavailable != null:
return relayUnavailable(_that);case ProgressKindView_Onboarding() when onboarding != null:
return onboarding(_that);case ProgressKindView_Gap() when gap != null:
return gap(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( ProgressKindView_MessageQueued value)  messageQueued,required TResult Function( ProgressKindView_MessageReceived value)  messageReceived,required TResult Function( ProgressKindView_EnvelopesPublished value)  envelopesPublished,required TResult Function( ProgressKindView_DeliveryChanged value)  deliveryChanged,required TResult Function( ProgressKindView_FileAnnounced value)  fileAnnounced,required TResult Function( ProgressKindView_FileTransfer value)  fileTransfer,required TResult Function( ProgressKindView_FileSaved value)  fileSaved,required TResult Function( ProgressKindView_Synced value)  synced,required TResult Function( ProgressKindView_PairingChanged value)  pairingChanged,required TResult Function( ProgressKindView_RelayUnavailable value)  relayUnavailable,required TResult Function( ProgressKindView_Onboarding value)  onboarding,required TResult Function( ProgressKindView_Gap value)  gap,}){
final _that = this;
switch (_that) {
case ProgressKindView_MessageQueued():
return messageQueued(_that);case ProgressKindView_MessageReceived():
return messageReceived(_that);case ProgressKindView_EnvelopesPublished():
return envelopesPublished(_that);case ProgressKindView_DeliveryChanged():
return deliveryChanged(_that);case ProgressKindView_FileAnnounced():
return fileAnnounced(_that);case ProgressKindView_FileTransfer():
return fileTransfer(_that);case ProgressKindView_FileSaved():
return fileSaved(_that);case ProgressKindView_Synced():
return synced(_that);case ProgressKindView_PairingChanged():
return pairingChanged(_that);case ProgressKindView_RelayUnavailable():
return relayUnavailable(_that);case ProgressKindView_Onboarding():
return onboarding(_that);case ProgressKindView_Gap():
return gap(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( ProgressKindView_MessageQueued value)?  messageQueued,TResult? Function( ProgressKindView_MessageReceived value)?  messageReceived,TResult? Function( ProgressKindView_EnvelopesPublished value)?  envelopesPublished,TResult? Function( ProgressKindView_DeliveryChanged value)?  deliveryChanged,TResult? Function( ProgressKindView_FileAnnounced value)?  fileAnnounced,TResult? Function( ProgressKindView_FileTransfer value)?  fileTransfer,TResult? Function( ProgressKindView_FileSaved value)?  fileSaved,TResult? Function( ProgressKindView_Synced value)?  synced,TResult? Function( ProgressKindView_PairingChanged value)?  pairingChanged,TResult? Function( ProgressKindView_RelayUnavailable value)?  relayUnavailable,TResult? Function( ProgressKindView_Onboarding value)?  onboarding,TResult? Function( ProgressKindView_Gap value)?  gap,}){
final _that = this;
switch (_that) {
case ProgressKindView_MessageQueued() when messageQueued != null:
return messageQueued(_that);case ProgressKindView_MessageReceived() when messageReceived != null:
return messageReceived(_that);case ProgressKindView_EnvelopesPublished() when envelopesPublished != null:
return envelopesPublished(_that);case ProgressKindView_DeliveryChanged() when deliveryChanged != null:
return deliveryChanged(_that);case ProgressKindView_FileAnnounced() when fileAnnounced != null:
return fileAnnounced(_that);case ProgressKindView_FileTransfer() when fileTransfer != null:
return fileTransfer(_that);case ProgressKindView_FileSaved() when fileSaved != null:
return fileSaved(_that);case ProgressKindView_Synced() when synced != null:
return synced(_that);case ProgressKindView_PairingChanged() when pairingChanged != null:
return pairingChanged(_that);case ProgressKindView_RelayUnavailable() when relayUnavailable != null:
return relayUnavailable(_that);case ProgressKindView_Onboarding() when onboarding != null:
return onboarding(_that);case ProgressKindView_Gap() when gap != null:
return gap(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String groupId,  String eventId)?  messageQueued,TResult Function( String groupId,  String eventId)?  messageReceived,TResult Function( int count,  bool pending)?  envelopesPublished,TResult Function( String deliveryId,  String state)?  deliveryChanged,TResult Function( String groupId,  String eventId,  String name,  BigInt size)?  fileAnnounced,TResult Function( String name,  BigInt offset,  BigInt? total)?  fileTransfer,TResult Function( String name)?  fileSaved,TResult Function( int fetched,  int new_,  int acked)?  synced,TResult Function( String sessionId,  String phase)?  pairingChanged,TResult Function( int pending)?  relayUnavailable,TResult Function( String step)?  onboarding,TResult Function( int dropped)?  gap,required TResult orElse(),}) {final _that = this;
switch (_that) {
case ProgressKindView_MessageQueued() when messageQueued != null:
return messageQueued(_that.groupId,_that.eventId);case ProgressKindView_MessageReceived() when messageReceived != null:
return messageReceived(_that.groupId,_that.eventId);case ProgressKindView_EnvelopesPublished() when envelopesPublished != null:
return envelopesPublished(_that.count,_that.pending);case ProgressKindView_DeliveryChanged() when deliveryChanged != null:
return deliveryChanged(_that.deliveryId,_that.state);case ProgressKindView_FileAnnounced() when fileAnnounced != null:
return fileAnnounced(_that.groupId,_that.eventId,_that.name,_that.size);case ProgressKindView_FileTransfer() when fileTransfer != null:
return fileTransfer(_that.name,_that.offset,_that.total);case ProgressKindView_FileSaved() when fileSaved != null:
return fileSaved(_that.name);case ProgressKindView_Synced() when synced != null:
return synced(_that.fetched,_that.new_,_that.acked);case ProgressKindView_PairingChanged() when pairingChanged != null:
return pairingChanged(_that.sessionId,_that.phase);case ProgressKindView_RelayUnavailable() when relayUnavailable != null:
return relayUnavailable(_that.pending);case ProgressKindView_Onboarding() when onboarding != null:
return onboarding(_that.step);case ProgressKindView_Gap() when gap != null:
return gap(_that.dropped);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String groupId,  String eventId)  messageQueued,required TResult Function( String groupId,  String eventId)  messageReceived,required TResult Function( int count,  bool pending)  envelopesPublished,required TResult Function( String deliveryId,  String state)  deliveryChanged,required TResult Function( String groupId,  String eventId,  String name,  BigInt size)  fileAnnounced,required TResult Function( String name,  BigInt offset,  BigInt? total)  fileTransfer,required TResult Function( String name)  fileSaved,required TResult Function( int fetched,  int new_,  int acked)  synced,required TResult Function( String sessionId,  String phase)  pairingChanged,required TResult Function( int pending)  relayUnavailable,required TResult Function( String step)  onboarding,required TResult Function( int dropped)  gap,}) {final _that = this;
switch (_that) {
case ProgressKindView_MessageQueued():
return messageQueued(_that.groupId,_that.eventId);case ProgressKindView_MessageReceived():
return messageReceived(_that.groupId,_that.eventId);case ProgressKindView_EnvelopesPublished():
return envelopesPublished(_that.count,_that.pending);case ProgressKindView_DeliveryChanged():
return deliveryChanged(_that.deliveryId,_that.state);case ProgressKindView_FileAnnounced():
return fileAnnounced(_that.groupId,_that.eventId,_that.name,_that.size);case ProgressKindView_FileTransfer():
return fileTransfer(_that.name,_that.offset,_that.total);case ProgressKindView_FileSaved():
return fileSaved(_that.name);case ProgressKindView_Synced():
return synced(_that.fetched,_that.new_,_that.acked);case ProgressKindView_PairingChanged():
return pairingChanged(_that.sessionId,_that.phase);case ProgressKindView_RelayUnavailable():
return relayUnavailable(_that.pending);case ProgressKindView_Onboarding():
return onboarding(_that.step);case ProgressKindView_Gap():
return gap(_that.dropped);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String groupId,  String eventId)?  messageQueued,TResult? Function( String groupId,  String eventId)?  messageReceived,TResult? Function( int count,  bool pending)?  envelopesPublished,TResult? Function( String deliveryId,  String state)?  deliveryChanged,TResult? Function( String groupId,  String eventId,  String name,  BigInt size)?  fileAnnounced,TResult? Function( String name,  BigInt offset,  BigInt? total)?  fileTransfer,TResult? Function( String name)?  fileSaved,TResult? Function( int fetched,  int new_,  int acked)?  synced,TResult? Function( String sessionId,  String phase)?  pairingChanged,TResult? Function( int pending)?  relayUnavailable,TResult? Function( String step)?  onboarding,TResult? Function( int dropped)?  gap,}) {final _that = this;
switch (_that) {
case ProgressKindView_MessageQueued() when messageQueued != null:
return messageQueued(_that.groupId,_that.eventId);case ProgressKindView_MessageReceived() when messageReceived != null:
return messageReceived(_that.groupId,_that.eventId);case ProgressKindView_EnvelopesPublished() when envelopesPublished != null:
return envelopesPublished(_that.count,_that.pending);case ProgressKindView_DeliveryChanged() when deliveryChanged != null:
return deliveryChanged(_that.deliveryId,_that.state);case ProgressKindView_FileAnnounced() when fileAnnounced != null:
return fileAnnounced(_that.groupId,_that.eventId,_that.name,_that.size);case ProgressKindView_FileTransfer() when fileTransfer != null:
return fileTransfer(_that.name,_that.offset,_that.total);case ProgressKindView_FileSaved() when fileSaved != null:
return fileSaved(_that.name);case ProgressKindView_Synced() when synced != null:
return synced(_that.fetched,_that.new_,_that.acked);case ProgressKindView_PairingChanged() when pairingChanged != null:
return pairingChanged(_that.sessionId,_that.phase);case ProgressKindView_RelayUnavailable() when relayUnavailable != null:
return relayUnavailable(_that.pending);case ProgressKindView_Onboarding() when onboarding != null:
return onboarding(_that.step);case ProgressKindView_Gap() when gap != null:
return gap(_that.dropped);case _:
  return null;

}
}

}

/// @nodoc


class ProgressKindView_MessageQueued extends ProgressKindView {
  const ProgressKindView_MessageQueued({required this.groupId, required this.eventId}): super._();
  

 final  String groupId;
 final  String eventId;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProgressKindView_MessageQueuedCopyWith<ProgressKindView_MessageQueued> get copyWith => _$ProgressKindView_MessageQueuedCopyWithImpl<ProgressKindView_MessageQueued>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProgressKindView_MessageQueued&&(identical(other.groupId, groupId) || other.groupId == groupId)&&(identical(other.eventId, eventId) || other.eventId == eventId));
}


@override
int get hashCode => Object.hash(runtimeType,groupId,eventId);

@override
String toString() {
  return 'ProgressKindView.messageQueued(groupId: $groupId, eventId: $eventId)';
}


}

/// @nodoc
abstract mixin class $ProgressKindView_MessageQueuedCopyWith<$Res> implements $ProgressKindViewCopyWith<$Res> {
  factory $ProgressKindView_MessageQueuedCopyWith(ProgressKindView_MessageQueued value, $Res Function(ProgressKindView_MessageQueued) _then) = _$ProgressKindView_MessageQueuedCopyWithImpl;
@useResult
$Res call({
 String groupId, String eventId
});




}
/// @nodoc
class _$ProgressKindView_MessageQueuedCopyWithImpl<$Res>
    implements $ProgressKindView_MessageQueuedCopyWith<$Res> {
  _$ProgressKindView_MessageQueuedCopyWithImpl(this._self, this._then);

  final ProgressKindView_MessageQueued _self;
  final $Res Function(ProgressKindView_MessageQueued) _then;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? groupId = null,Object? eventId = null,}) {
  return _then(ProgressKindView_MessageQueued(
groupId: null == groupId ? _self.groupId : groupId // ignore: cast_nullable_to_non_nullable
as String,eventId: null == eventId ? _self.eventId : eventId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ProgressKindView_MessageReceived extends ProgressKindView {
  const ProgressKindView_MessageReceived({required this.groupId, required this.eventId}): super._();
  

 final  String groupId;
 final  String eventId;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProgressKindView_MessageReceivedCopyWith<ProgressKindView_MessageReceived> get copyWith => _$ProgressKindView_MessageReceivedCopyWithImpl<ProgressKindView_MessageReceived>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProgressKindView_MessageReceived&&(identical(other.groupId, groupId) || other.groupId == groupId)&&(identical(other.eventId, eventId) || other.eventId == eventId));
}


@override
int get hashCode => Object.hash(runtimeType,groupId,eventId);

@override
String toString() {
  return 'ProgressKindView.messageReceived(groupId: $groupId, eventId: $eventId)';
}


}

/// @nodoc
abstract mixin class $ProgressKindView_MessageReceivedCopyWith<$Res> implements $ProgressKindViewCopyWith<$Res> {
  factory $ProgressKindView_MessageReceivedCopyWith(ProgressKindView_MessageReceived value, $Res Function(ProgressKindView_MessageReceived) _then) = _$ProgressKindView_MessageReceivedCopyWithImpl;
@useResult
$Res call({
 String groupId, String eventId
});




}
/// @nodoc
class _$ProgressKindView_MessageReceivedCopyWithImpl<$Res>
    implements $ProgressKindView_MessageReceivedCopyWith<$Res> {
  _$ProgressKindView_MessageReceivedCopyWithImpl(this._self, this._then);

  final ProgressKindView_MessageReceived _self;
  final $Res Function(ProgressKindView_MessageReceived) _then;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? groupId = null,Object? eventId = null,}) {
  return _then(ProgressKindView_MessageReceived(
groupId: null == groupId ? _self.groupId : groupId // ignore: cast_nullable_to_non_nullable
as String,eventId: null == eventId ? _self.eventId : eventId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ProgressKindView_EnvelopesPublished extends ProgressKindView {
  const ProgressKindView_EnvelopesPublished({required this.count, required this.pending}): super._();
  

 final  int count;
 final  bool pending;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProgressKindView_EnvelopesPublishedCopyWith<ProgressKindView_EnvelopesPublished> get copyWith => _$ProgressKindView_EnvelopesPublishedCopyWithImpl<ProgressKindView_EnvelopesPublished>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProgressKindView_EnvelopesPublished&&(identical(other.count, count) || other.count == count)&&(identical(other.pending, pending) || other.pending == pending));
}


@override
int get hashCode => Object.hash(runtimeType,count,pending);

@override
String toString() {
  return 'ProgressKindView.envelopesPublished(count: $count, pending: $pending)';
}


}

/// @nodoc
abstract mixin class $ProgressKindView_EnvelopesPublishedCopyWith<$Res> implements $ProgressKindViewCopyWith<$Res> {
  factory $ProgressKindView_EnvelopesPublishedCopyWith(ProgressKindView_EnvelopesPublished value, $Res Function(ProgressKindView_EnvelopesPublished) _then) = _$ProgressKindView_EnvelopesPublishedCopyWithImpl;
@useResult
$Res call({
 int count, bool pending
});




}
/// @nodoc
class _$ProgressKindView_EnvelopesPublishedCopyWithImpl<$Res>
    implements $ProgressKindView_EnvelopesPublishedCopyWith<$Res> {
  _$ProgressKindView_EnvelopesPublishedCopyWithImpl(this._self, this._then);

  final ProgressKindView_EnvelopesPublished _self;
  final $Res Function(ProgressKindView_EnvelopesPublished) _then;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? count = null,Object? pending = null,}) {
  return _then(ProgressKindView_EnvelopesPublished(
count: null == count ? _self.count : count // ignore: cast_nullable_to_non_nullable
as int,pending: null == pending ? _self.pending : pending // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class ProgressKindView_DeliveryChanged extends ProgressKindView {
  const ProgressKindView_DeliveryChanged({required this.deliveryId, required this.state}): super._();
  

 final  String deliveryId;
 final  String state;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProgressKindView_DeliveryChangedCopyWith<ProgressKindView_DeliveryChanged> get copyWith => _$ProgressKindView_DeliveryChangedCopyWithImpl<ProgressKindView_DeliveryChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProgressKindView_DeliveryChanged&&(identical(other.deliveryId, deliveryId) || other.deliveryId == deliveryId)&&(identical(other.state, state) || other.state == state));
}


@override
int get hashCode => Object.hash(runtimeType,deliveryId,state);

@override
String toString() {
  return 'ProgressKindView.deliveryChanged(deliveryId: $deliveryId, state: $state)';
}


}

/// @nodoc
abstract mixin class $ProgressKindView_DeliveryChangedCopyWith<$Res> implements $ProgressKindViewCopyWith<$Res> {
  factory $ProgressKindView_DeliveryChangedCopyWith(ProgressKindView_DeliveryChanged value, $Res Function(ProgressKindView_DeliveryChanged) _then) = _$ProgressKindView_DeliveryChangedCopyWithImpl;
@useResult
$Res call({
 String deliveryId, String state
});




}
/// @nodoc
class _$ProgressKindView_DeliveryChangedCopyWithImpl<$Res>
    implements $ProgressKindView_DeliveryChangedCopyWith<$Res> {
  _$ProgressKindView_DeliveryChangedCopyWithImpl(this._self, this._then);

  final ProgressKindView_DeliveryChanged _self;
  final $Res Function(ProgressKindView_DeliveryChanged) _then;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? deliveryId = null,Object? state = null,}) {
  return _then(ProgressKindView_DeliveryChanged(
deliveryId: null == deliveryId ? _self.deliveryId : deliveryId // ignore: cast_nullable_to_non_nullable
as String,state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ProgressKindView_FileAnnounced extends ProgressKindView {
  const ProgressKindView_FileAnnounced({required this.groupId, required this.eventId, required this.name, required this.size}): super._();
  

 final  String groupId;
 final  String eventId;
 final  String name;
 final  BigInt size;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProgressKindView_FileAnnouncedCopyWith<ProgressKindView_FileAnnounced> get copyWith => _$ProgressKindView_FileAnnouncedCopyWithImpl<ProgressKindView_FileAnnounced>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProgressKindView_FileAnnounced&&(identical(other.groupId, groupId) || other.groupId == groupId)&&(identical(other.eventId, eventId) || other.eventId == eventId)&&(identical(other.name, name) || other.name == name)&&(identical(other.size, size) || other.size == size));
}


@override
int get hashCode => Object.hash(runtimeType,groupId,eventId,name,size);

@override
String toString() {
  return 'ProgressKindView.fileAnnounced(groupId: $groupId, eventId: $eventId, name: $name, size: $size)';
}


}

/// @nodoc
abstract mixin class $ProgressKindView_FileAnnouncedCopyWith<$Res> implements $ProgressKindViewCopyWith<$Res> {
  factory $ProgressKindView_FileAnnouncedCopyWith(ProgressKindView_FileAnnounced value, $Res Function(ProgressKindView_FileAnnounced) _then) = _$ProgressKindView_FileAnnouncedCopyWithImpl;
@useResult
$Res call({
 String groupId, String eventId, String name, BigInt size
});




}
/// @nodoc
class _$ProgressKindView_FileAnnouncedCopyWithImpl<$Res>
    implements $ProgressKindView_FileAnnouncedCopyWith<$Res> {
  _$ProgressKindView_FileAnnouncedCopyWithImpl(this._self, this._then);

  final ProgressKindView_FileAnnounced _self;
  final $Res Function(ProgressKindView_FileAnnounced) _then;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? groupId = null,Object? eventId = null,Object? name = null,Object? size = null,}) {
  return _then(ProgressKindView_FileAnnounced(
groupId: null == groupId ? _self.groupId : groupId // ignore: cast_nullable_to_non_nullable
as String,eventId: null == eventId ? _self.eventId : eventId // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,size: null == size ? _self.size : size // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class ProgressKindView_FileTransfer extends ProgressKindView {
  const ProgressKindView_FileTransfer({required this.name, required this.offset, this.total}): super._();
  

 final  String name;
 final  BigInt offset;
 final  BigInt? total;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProgressKindView_FileTransferCopyWith<ProgressKindView_FileTransfer> get copyWith => _$ProgressKindView_FileTransferCopyWithImpl<ProgressKindView_FileTransfer>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProgressKindView_FileTransfer&&(identical(other.name, name) || other.name == name)&&(identical(other.offset, offset) || other.offset == offset)&&(identical(other.total, total) || other.total == total));
}


@override
int get hashCode => Object.hash(runtimeType,name,offset,total);

@override
String toString() {
  return 'ProgressKindView.fileTransfer(name: $name, offset: $offset, total: $total)';
}


}

/// @nodoc
abstract mixin class $ProgressKindView_FileTransferCopyWith<$Res> implements $ProgressKindViewCopyWith<$Res> {
  factory $ProgressKindView_FileTransferCopyWith(ProgressKindView_FileTransfer value, $Res Function(ProgressKindView_FileTransfer) _then) = _$ProgressKindView_FileTransferCopyWithImpl;
@useResult
$Res call({
 String name, BigInt offset, BigInt? total
});




}
/// @nodoc
class _$ProgressKindView_FileTransferCopyWithImpl<$Res>
    implements $ProgressKindView_FileTransferCopyWith<$Res> {
  _$ProgressKindView_FileTransferCopyWithImpl(this._self, this._then);

  final ProgressKindView_FileTransfer _self;
  final $Res Function(ProgressKindView_FileTransfer) _then;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? name = null,Object? offset = null,Object? total = freezed,}) {
  return _then(ProgressKindView_FileTransfer(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,offset: null == offset ? _self.offset : offset // ignore: cast_nullable_to_non_nullable
as BigInt,total: freezed == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as BigInt?,
  ));
}


}

/// @nodoc


class ProgressKindView_FileSaved extends ProgressKindView {
  const ProgressKindView_FileSaved({required this.name}): super._();
  

 final  String name;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProgressKindView_FileSavedCopyWith<ProgressKindView_FileSaved> get copyWith => _$ProgressKindView_FileSavedCopyWithImpl<ProgressKindView_FileSaved>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProgressKindView_FileSaved&&(identical(other.name, name) || other.name == name));
}


@override
int get hashCode => Object.hash(runtimeType,name);

@override
String toString() {
  return 'ProgressKindView.fileSaved(name: $name)';
}


}

/// @nodoc
abstract mixin class $ProgressKindView_FileSavedCopyWith<$Res> implements $ProgressKindViewCopyWith<$Res> {
  factory $ProgressKindView_FileSavedCopyWith(ProgressKindView_FileSaved value, $Res Function(ProgressKindView_FileSaved) _then) = _$ProgressKindView_FileSavedCopyWithImpl;
@useResult
$Res call({
 String name
});




}
/// @nodoc
class _$ProgressKindView_FileSavedCopyWithImpl<$Res>
    implements $ProgressKindView_FileSavedCopyWith<$Res> {
  _$ProgressKindView_FileSavedCopyWithImpl(this._self, this._then);

  final ProgressKindView_FileSaved _self;
  final $Res Function(ProgressKindView_FileSaved) _then;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? name = null,}) {
  return _then(ProgressKindView_FileSaved(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ProgressKindView_Synced extends ProgressKindView {
  const ProgressKindView_Synced({required this.fetched, required this.new_, required this.acked}): super._();
  

 final  int fetched;
 final  int new_;
 final  int acked;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProgressKindView_SyncedCopyWith<ProgressKindView_Synced> get copyWith => _$ProgressKindView_SyncedCopyWithImpl<ProgressKindView_Synced>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProgressKindView_Synced&&(identical(other.fetched, fetched) || other.fetched == fetched)&&(identical(other.new_, new_) || other.new_ == new_)&&(identical(other.acked, acked) || other.acked == acked));
}


@override
int get hashCode => Object.hash(runtimeType,fetched,new_,acked);

@override
String toString() {
  return 'ProgressKindView.synced(fetched: $fetched, new_: $new_, acked: $acked)';
}


}

/// @nodoc
abstract mixin class $ProgressKindView_SyncedCopyWith<$Res> implements $ProgressKindViewCopyWith<$Res> {
  factory $ProgressKindView_SyncedCopyWith(ProgressKindView_Synced value, $Res Function(ProgressKindView_Synced) _then) = _$ProgressKindView_SyncedCopyWithImpl;
@useResult
$Res call({
 int fetched, int new_, int acked
});




}
/// @nodoc
class _$ProgressKindView_SyncedCopyWithImpl<$Res>
    implements $ProgressKindView_SyncedCopyWith<$Res> {
  _$ProgressKindView_SyncedCopyWithImpl(this._self, this._then);

  final ProgressKindView_Synced _self;
  final $Res Function(ProgressKindView_Synced) _then;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? fetched = null,Object? new_ = null,Object? acked = null,}) {
  return _then(ProgressKindView_Synced(
fetched: null == fetched ? _self.fetched : fetched // ignore: cast_nullable_to_non_nullable
as int,new_: null == new_ ? _self.new_ : new_ // ignore: cast_nullable_to_non_nullable
as int,acked: null == acked ? _self.acked : acked // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class ProgressKindView_PairingChanged extends ProgressKindView {
  const ProgressKindView_PairingChanged({required this.sessionId, required this.phase}): super._();
  

 final  String sessionId;
 final  String phase;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProgressKindView_PairingChangedCopyWith<ProgressKindView_PairingChanged> get copyWith => _$ProgressKindView_PairingChangedCopyWithImpl<ProgressKindView_PairingChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProgressKindView_PairingChanged&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.phase, phase) || other.phase == phase));
}


@override
int get hashCode => Object.hash(runtimeType,sessionId,phase);

@override
String toString() {
  return 'ProgressKindView.pairingChanged(sessionId: $sessionId, phase: $phase)';
}


}

/// @nodoc
abstract mixin class $ProgressKindView_PairingChangedCopyWith<$Res> implements $ProgressKindViewCopyWith<$Res> {
  factory $ProgressKindView_PairingChangedCopyWith(ProgressKindView_PairingChanged value, $Res Function(ProgressKindView_PairingChanged) _then) = _$ProgressKindView_PairingChangedCopyWithImpl;
@useResult
$Res call({
 String sessionId, String phase
});




}
/// @nodoc
class _$ProgressKindView_PairingChangedCopyWithImpl<$Res>
    implements $ProgressKindView_PairingChangedCopyWith<$Res> {
  _$ProgressKindView_PairingChangedCopyWithImpl(this._self, this._then);

  final ProgressKindView_PairingChanged _self;
  final $Res Function(ProgressKindView_PairingChanged) _then;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sessionId = null,Object? phase = null,}) {
  return _then(ProgressKindView_PairingChanged(
sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,phase: null == phase ? _self.phase : phase // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ProgressKindView_RelayUnavailable extends ProgressKindView {
  const ProgressKindView_RelayUnavailable({required this.pending}): super._();
  

 final  int pending;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProgressKindView_RelayUnavailableCopyWith<ProgressKindView_RelayUnavailable> get copyWith => _$ProgressKindView_RelayUnavailableCopyWithImpl<ProgressKindView_RelayUnavailable>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProgressKindView_RelayUnavailable&&(identical(other.pending, pending) || other.pending == pending));
}


@override
int get hashCode => Object.hash(runtimeType,pending);

@override
String toString() {
  return 'ProgressKindView.relayUnavailable(pending: $pending)';
}


}

/// @nodoc
abstract mixin class $ProgressKindView_RelayUnavailableCopyWith<$Res> implements $ProgressKindViewCopyWith<$Res> {
  factory $ProgressKindView_RelayUnavailableCopyWith(ProgressKindView_RelayUnavailable value, $Res Function(ProgressKindView_RelayUnavailable) _then) = _$ProgressKindView_RelayUnavailableCopyWithImpl;
@useResult
$Res call({
 int pending
});




}
/// @nodoc
class _$ProgressKindView_RelayUnavailableCopyWithImpl<$Res>
    implements $ProgressKindView_RelayUnavailableCopyWith<$Res> {
  _$ProgressKindView_RelayUnavailableCopyWithImpl(this._self, this._then);

  final ProgressKindView_RelayUnavailable _self;
  final $Res Function(ProgressKindView_RelayUnavailable) _then;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? pending = null,}) {
  return _then(ProgressKindView_RelayUnavailable(
pending: null == pending ? _self.pending : pending // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class ProgressKindView_Onboarding extends ProgressKindView {
  const ProgressKindView_Onboarding({required this.step}): super._();
  

 final  String step;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProgressKindView_OnboardingCopyWith<ProgressKindView_Onboarding> get copyWith => _$ProgressKindView_OnboardingCopyWithImpl<ProgressKindView_Onboarding>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProgressKindView_Onboarding&&(identical(other.step, step) || other.step == step));
}


@override
int get hashCode => Object.hash(runtimeType,step);

@override
String toString() {
  return 'ProgressKindView.onboarding(step: $step)';
}


}

/// @nodoc
abstract mixin class $ProgressKindView_OnboardingCopyWith<$Res> implements $ProgressKindViewCopyWith<$Res> {
  factory $ProgressKindView_OnboardingCopyWith(ProgressKindView_Onboarding value, $Res Function(ProgressKindView_Onboarding) _then) = _$ProgressKindView_OnboardingCopyWithImpl;
@useResult
$Res call({
 String step
});




}
/// @nodoc
class _$ProgressKindView_OnboardingCopyWithImpl<$Res>
    implements $ProgressKindView_OnboardingCopyWith<$Res> {
  _$ProgressKindView_OnboardingCopyWithImpl(this._self, this._then);

  final ProgressKindView_Onboarding _self;
  final $Res Function(ProgressKindView_Onboarding) _then;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? step = null,}) {
  return _then(ProgressKindView_Onboarding(
step: null == step ? _self.step : step // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ProgressKindView_Gap extends ProgressKindView {
  const ProgressKindView_Gap({required this.dropped}): super._();
  

 final  int dropped;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProgressKindView_GapCopyWith<ProgressKindView_Gap> get copyWith => _$ProgressKindView_GapCopyWithImpl<ProgressKindView_Gap>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProgressKindView_Gap&&(identical(other.dropped, dropped) || other.dropped == dropped));
}


@override
int get hashCode => Object.hash(runtimeType,dropped);

@override
String toString() {
  return 'ProgressKindView.gap(dropped: $dropped)';
}


}

/// @nodoc
abstract mixin class $ProgressKindView_GapCopyWith<$Res> implements $ProgressKindViewCopyWith<$Res> {
  factory $ProgressKindView_GapCopyWith(ProgressKindView_Gap value, $Res Function(ProgressKindView_Gap) _then) = _$ProgressKindView_GapCopyWithImpl;
@useResult
$Res call({
 int dropped
});




}
/// @nodoc
class _$ProgressKindView_GapCopyWithImpl<$Res>
    implements $ProgressKindView_GapCopyWith<$Res> {
  _$ProgressKindView_GapCopyWithImpl(this._self, this._then);

  final ProgressKindView_Gap _self;
  final $Res Function(ProgressKindView_Gap) _then;

/// Create a copy of ProgressKindView
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? dropped = null,}) {
  return _then(ProgressKindView_Gap(
dropped: null == dropped ? _self.dropped : dropped // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

// dart format on
