// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of protobuf;

Map<String, dynamic> _writeToJsonMap(_FieldSet fs) {
  convertToMap(dynamic fieldValue, int fieldType) {
    int baseType = PbFieldType._baseType(fieldType);

    if (_isRepeated(fieldType)) {
      return List.from(fieldValue.map((e) => convertToMap(e, baseType)));
    }

    switch (baseType) {
      case PbFieldType._BOOL_BIT:
      case PbFieldType._STRING_BIT:
      case PbFieldType._FLOAT_BIT:
      case PbFieldType._DOUBLE_BIT:
      case PbFieldType._INT32_BIT:
      case PbFieldType._SINT32_BIT:
      case PbFieldType._UINT32_BIT:
      case PbFieldType._FIXED32_BIT:
      case PbFieldType._SFIXED32_BIT:
        return fieldValue;
      case PbFieldType._BYTES_BIT:
        // Encode 'bytes' as a base64-encoded string.
        return base64Encode(fieldValue as List<int>);
      case PbFieldType._ENUM_BIT:
        return fieldValue.value; // assume |value| < 2^52
      case PbFieldType._INT64_BIT:
      case PbFieldType._SINT64_BIT:
      case PbFieldType._SFIXED64_BIT:
        return fieldValue.toString();
      case PbFieldType._UINT64_BIT:
      case PbFieldType._FIXED64_BIT:
        return fieldValue.toStringUnsigned();
      case PbFieldType._GROUP_BIT:
      case PbFieldType._MESSAGE_BIT:
        return fieldValue.writeToJsonMap();
      default:
        throw 'Unknown type $fieldType';
    }
  }

  _writeMap(dynamic fieldValue, MapFieldInfo fi) {
    return List.from(fieldValue.entries.map((MapEntry e) => {
          '${PbMap._keyFieldNumber}': convertToMap(e.key, fi.keyFieldType),
          '${PbMap._valueFieldNumber}': convertToMap(e.value, fi.valueFieldType)
        }));
  }

  var result = <String, dynamic>{};
  for (var fi in fs._infosSortedByTag) {
    var value = fs._values[fi.index];
    if (value == null || (value is List && value.isEmpty)) {
      continue; // It's missing, repeated, or an empty byte array.
    }
    if (_isMapField(fi.type)) {
      result['${fi.tagNumber}'] = _writeMap(value, fi);
      continue;
    }
    result['${fi.tagNumber}'] = convertToMap(value, fi.type);
  }
  if (fs._hasExtensions) {
    for (int tagNumber in _sorted(fs._extensions._tagNumbers)) {
      var value = fs._extensions._values[tagNumber];
      if (value is List && value.isEmpty) {
        continue; // It's repeated or an empty byte array.
      }
      var fi = fs._extensions._getInfoOrNull(tagNumber);
      result['$tagNumber'] = convertToMap(value, fi.type);
    }
  }
  return result;
}

// Merge fields from a previously decoded JSON object.
// (Called recursively on nested messages.)
void _mergeFromJsonReader(
    _FieldSet fs, JsonReader jsonReader, ExtensionRegistry registry) {
  jsonReader.expectObject();
  String key;
  var meta = fs._meta;
  while ((key = jsonReader.nextKey()) != null) {
    var fi = meta.byTagAsString[key];
    if (fi == null) {
      if (registry == null) continue; // Unknown tag; skip
      fi = registry.getExtension(fs._messageName, int.parse(key));
      if (fi == null) continue; // Unknown tag; skip
    }
    if (fi.isMapField) {
      _appendJsonMap(fs, jsonReader, fi, registry);
    } else if (fi.isRepeated) {
      _appendJsonList(fs, jsonReader, fi, registry);
    } else {
      _setJsonField(fs, jsonReader, fi, registry);
    }
  }
}

void _appendJsonList(_FieldSet fs, JsonReader jsonReader, FieldInfo fi,
    ExtensionRegistry registry) {
  var repeated = fi._ensureRepeatedField(fs);
  // Micro optimization. Using "for in" generates the following and iterator
  // alloc:
  //   for (t1 = J.get$iterator$ax(json), t2 = fi.tagNumber, t3 = fi.type,
  //       t4 = J.getInterceptor$ax(repeated); t1.moveNext$0();)
  jsonReader.expectArray();
  while (jsonReader.hasNext()) {
    var convertedValue =
        _convertJsonValue(fs, jsonReader, fi.tagNumber, fi.type, registry);
    if (convertedValue != null) {
      repeated.add(convertedValue);
    }
  }
}

const _pbMapKeyFieldNumber = '${PbMap._keyFieldNumber}';
const _pbMapValueFieldNumber = '${PbMap._valueFieldNumber}';

void _appendJsonMap(_FieldSet fs, JsonReader jsonReader, MapFieldInfo fi,
    ExtensionRegistry registry) {
  jsonReader.expectArray();
  PbMap map = fi._ensureMapField(fs);
  while (jsonReader.hasNext()) {
    _FieldSet entryFieldSet = map._entryFieldSet();
    jsonReader.expectObject();
    String key;
    var convertedKey;
    var convertedValue;
    while ((key = jsonString(jsonReader)) != null) {
      switch (key) {
        case _pbMapKeyFieldNumber:
          convertedKey = _convertJsonValue(entryFieldSet, jsonReader,
              PbMap._keyFieldNumber, fi.keyFieldType, registry);
          break;
        case _pbMapValueFieldNumber:
          convertedValue = _convertJsonValue(entryFieldSet, jsonReader,
              PbMap._valueFieldNumber, fi.valueFieldType, registry);
          break;
      }
    }
    map[convertedKey] = convertedValue;
  }
}

void _setJsonField(
    _FieldSet fs, JsonReader json, FieldInfo fi, ExtensionRegistry registry) {
  var value = _convertJsonValue(fs, json, fi.tagNumber, fi.type, registry);
  if (value == null) return;
  // _convertJsonValue throws exception when it fails to do conversion.
  // Therefore we run _validateField for debug builds only to validate
  // correctness of conversion.
  assert(() {
    fs._validateField(fi, value);
    return true;
  }());
  fs._setFieldUnchecked(fi, value);
}

/// Converts [value] from the Json format to the Dart data type
/// suitable for inserting into the corresponding [GeneratedMessage] field.
///
/// Returns the converted value.  This function returns [null] if the caller
/// should ignore the field value, because it is an unknown enum value.
/// This function throws [ArgumentError] if it cannot convert the value.
_convertJsonValue(_FieldSet fs, JsonReader reader, int tagNumber, int fieldType,
    ExtensionRegistry registry) {
  String expectedType; // for exception message
  switch (PbFieldType._baseType(fieldType)) {
    case PbFieldType._BOOL_BIT:
      if (reader.checkBool()) {
        return reader.expectBool();
      } else if (reader.checkString()) {
        var value = reader.expectString();
        if (value == 'true') {
          return true;
        } else if (value == 'false') {
          return false;
        }
      } else if (reader.checkNum()) {
        var value = reader.expectNum();
        if (value == 1) {
          return true;
        } else if (value == 0) {
          return false;
        }
      }
      expectedType = 'bool (true, false, "true", "false", 1, 0)';
      break;
    case PbFieldType._BYTES_BIT:
      if (reader.checkString()) {
        return base64Decode(reader.expectString());
      }
      expectedType = 'Base64 String';
      break;
    case PbFieldType._STRING_BIT:
      if (reader.checkString()) {
        return reader.expectString();
      }
      expectedType = 'String';
      break;
    case PbFieldType._FLOAT_BIT:
    case PbFieldType._DOUBLE_BIT:
      // Allow quoted values, although we don't emit them.
      if (reader.checkNum()) {
        return reader.expectDouble();
        // } else if (value is num) {
        //   return value.toDouble();
      } else if (reader.checkString()) {
        return double.parse(reader.expectString());
      }
      expectedType = 'num or stringified num';
      break;
    case PbFieldType._ENUM_BIT:
      int value;
      // Allow quoted values, although we don't emit them.
      if (reader.checkString()) {
        value = int.parse(reader.expectString());
      } else {
        value = reader.expectInt();
      }
      if (value is int) {
        // The following call will return null if the enum value is unknown.
        // In that case, we want the caller to ignore this value, so we return
        // null from this method as well.
        return fs._meta._decodeEnum(tagNumber, registry, value);
      }
      expectedType = 'int or stringified int';
      break;
    case PbFieldType._INT32_BIT:
    case PbFieldType._SINT32_BIT:
    case PbFieldType._UINT32_BIT:
    case PbFieldType._FIXED32_BIT:
    case PbFieldType._SFIXED32_BIT:
      if (reader.checkNum()) return reader.expectInt();
      if (reader.checkString()) return int.parse(reader.expectString());
      expectedType = 'int or stringified int';
      break;
    case PbFieldType._INT64_BIT:
    case PbFieldType._SINT64_BIT:
    case PbFieldType._UINT64_BIT:
    case PbFieldType._FIXED64_BIT:
    case PbFieldType._SFIXED64_BIT:
      if (reader.checkNum()) return Int64(reader.expectInt());
      if (reader.checkString()) return Int64.parseInt(reader.expectString());
      expectedType = 'int or stringified int';
      break;
    case PbFieldType._GROUP_BIT:
    case PbFieldType._MESSAGE_BIT:
      if (reader.checkObject()) {
        GeneratedMessage subMessage =
            fs._meta._makeEmptyMessage(tagNumber, registry);
        _mergeFromJsonReader(subMessage._fieldSet, reader, registry);
        return subMessage;
      }
      expectedType = 'nested message or group';
      break;
    default:
      throw ArgumentError('Unknown type $fieldType');
  }
  throw ArgumentError('Expected type $expectedType, got ${jsonValue(reader)}');
}
