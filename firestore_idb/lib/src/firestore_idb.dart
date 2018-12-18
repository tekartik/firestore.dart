import 'dart:async';

import 'package:path/path.dart';
import 'package:tekartik_common_utils/common_utils_import.dart';
import 'package:tekartik_firebase_firestore/utils/firestore_mixin.dart';
import 'package:tekartik_firebase_firestore/utils/json_utils.dart';
import 'package:tekartik_firebase_local/firebase_local.dart';
import 'package:idb_shim/idb.dart' as idb;
import 'package:tekartik_firebase/firebase.dart';
import 'package:tekartik_firebase_firestore/firestore.dart';
import 'package:tekartik_firebase_firestore/utils/document_data.dart';
import 'package:tekartik_firebase_firestore/src/firestore.dart';
import 'package:uuid/uuid.dart';

const String parentIndexName = 'parentIndex';

class FirestoreServiceIdb implements FirestoreService {
  final idb.IdbFactory idbFactory;

  FirestoreServiceIdb(this.idbFactory);

  @override
  bool get supportsQuerySelect => false;

  @override
  bool get supportsDocumentSnapshotTime => false;

  @override
  bool get supportsTimestampsInSnapshots => false;

  @override
  bool get supportsTimestamps => false;

  @override
  Firestore firestore(App app) {
    assert(app is AppLocal, 'invalid firebase app type');
    AppLocal appLocal = app;
    return FirestoreIdb(appLocal, this);
  }

  @override
  bool get supportsQuerySnapshotCursor => true;
}

FirestoreService getFirestoreService(idb.IdbFactory idbFactory) =>
    FirestoreServiceIdb(idbFactory);

class FirestoreIdb extends Object
    with FirestoreMixin, FirestoreSubscriptionMixin, FirestoreDocumentsMixin
    implements Firestore {
  final AppLocal appLocal;
  final FirestoreServiceIdb firestoreServiceIdb;
  idb.IdbFactory get idbFactory => firestoreServiceIdb.idbFactory;
  idb.Database _database;
  FutureOr<idb.Database> get databaseReady {
    if (_database != null) {
      return _database;
    }
    return idbFactory.open(appLocal.localPath, version: 1,
        onUpgradeNeeded: (idb.VersionChangeEvent versionChangeEvent) {
      // devPrint('old version ${versionChangeEvent.oldVersion}');
      // Just on object store
      if (versionChangeEvent.oldVersion == 0) {
        versionChangeEvent.database.createObjectStore(storeName);
      }
    }).then((idb.Database database) {
      _database = database;
      return _database;
    });
  }

  FirestoreIdb(this.appLocal, this.firestoreServiceIdb);

  @override
  CollectionReference collection(String path) =>
      CollectionReferenceIdb(this, path);

  @override
  DocumentReference doc(String path) => getDocumentRef(path);

  DocumentReferenceIdb getDocumentRef(String path) =>
      DocumentReferenceIdb(this, path);

  @override
  WriteBatch batch() => WriteBatchIdb(this);

  @override
  Future runTransaction(
      Function(Transaction transaction) updateFunction) async {
    var localTransaction = await getReadWriteTransaction();
    var txn = TransactionIdb(this, localTransaction);
    await updateFunction(txn);
    await localTransaction.completed;
    localTransaction.notify();
  }

  @override
  Future<List<DocumentSnapshot>> getAll(List<DocumentReference> refs) async {
    return await Future.wait(refs.map((ref) => ref.get()));
  }

  Future<DocumentReferenceIdb> add(
      String path, Map<String, dynamic> data) async {
    var documentData = DocumentData(data);
    var localTransaction = await getReadWriteTransaction();
    var txn = localTransaction.transaction;
    var documentRef = getDocumentRef(_generateId());
    await txn
        .objectStore(storeName)
        .add(documentDataToJsonMap(documentData), documentRef.path);
    await txn.completed;
    return documentRef;
  }

  Future<DocumentReferenceIdb> setDocument(DocumentReferenceIdb documentRef,
      DocumentData documentData, SetOptions options) async {
    var localTransaction = await getReadWriteTransaction();
    await txnSet(localTransaction, documentRef, documentData, options);
    await localTransaction.completed;
    return documentRef;
  }

  Future<DocumentReferenceIdb> updateDocument(
      DocumentReferenceIdb documentRef, DocumentData documentData) async {
    var localTransaction = await getReadWriteTransaction();
    await txnUpdate(localTransaction, documentRef, documentData);
    await localTransaction.completed;
    return documentRef;
  }

  String get storeName => 'documents';
  Future<LocalTransaction> getReadWriteTransaction() async {
    idb.Database db = await databaseReady;
    var txn = db.transaction(storeName, idb.idbModeReadWrite);
    LocalTransaction localTransaction = LocalTransaction(this, txn);
    return localTransaction;
  }

  Future deleteDocument(DocumentReferenceIdb documentReferenceIdb) async {
    var localTransaction = await getReadWriteTransaction();
    await txnDelete(localTransaction, documentReferenceIdb);
    await localTransaction.completed;
  }

  Future<WriteResultIdb> txnDelete(
      LocalTransaction localTransaction, DocumentReferenceIdb ref) {
    var result = WriteResultIdb(ref.path);
    var txn = localTransaction.transaction;
    // read the previous one for the notifications
    return txnGet(localTransaction, ref).then((snapshot) {
      result.previousSnapshot = snapshot;
      return txn.objectStore(storeName).delete(ref.path);
    }).then((_) {
      return result;
    });
  }

  Future<DocumentSnapshotIdb> txnGet(LocalTransaction localTransaction,
      DocumentReferenceIdb documentReferenceIdb) {
    var txn = localTransaction.transaction;
    return txn
        .objectStore(storeName)
        .getObject(documentReferenceIdb.path)
        .then((value) {
      // we assume it is always a map
      Map<String, dynamic> recordMap = (value as Map)?.cast<String, dynamic>();

      return DocumentSnapshotIdb(
          documentReferenceIdb,
          RecordMetaData.fromRecordMap(recordMap),
          documentDataFromRecordMap(this, recordMap));
    });
  }

  Future<DocumentSnapshotIdb> getDocument(
      DocumentReferenceIdb documentRef) async {
    var localTransaction = await getReadWriteTransaction();
    return txnGet(localTransaction, documentRef);
  }

  Future<WriteResultIdb> txnSet(
      LocalTransaction localTransaction,
      DocumentReferenceIdb documentRef,
      DocumentData documentData,
      SetOptions options) {
    var result = WriteResultIdb(documentRef.path);
    var txn = localTransaction.transaction;
    return txnGet(localTransaction, documentRef).then((snapshot) {
      result.previousSnapshot = snapshot;

      /*
      Map<String, dynamic> recordMap;

      // Update rev
      int rev = (snapshot?.rev ?? 0) + 1;
      // merging?
      if (options?.merge == true) {
        recordMap = documentDataToRecordMap(documentData, documentFromRecordMap(documentRef, sna, recordMap)existingRecordMap);
      } else {
        recordMap = documentDataToRecordMap(documentData);
      }

      if (recordMap != null) {
        recordMap[revKey] = rev;
      }

      // set update Time
      if (recordMap != null) {
        var now = Timestamp.now();
        recordMap[createTimeKey] =
            (result.previousSnapshot?.createTime ?? now).toIso8601String();
        recordMap[updateTimeKey] = now.toIso8601String();
      }


      result.newSnapshot = this.documentFromRecordMap(ref, recordMap);
      */
      // TODO
      return txn
          .objectStore(storeName)
          .put(documentDataToRecordMap(documentData), documentRef.path)
          .then((_) {
        return result;
      });
    });
  }

  Future<WriteResultIdb> txnUpdate(LocalTransaction localTransaction,
      DocumentReferenceIdb documentRef, DocumentData documentData) {
    var result = WriteResultIdb(documentRef.path);
    return txnGet(localTransaction, documentRef)
        .then((DocumentSnapshotIdb snapshotIdb) {
      var map = snapshotIdb.data;
      // TODO
      map = documentDataToUpdateMap(documentData);
      return localTransaction.transaction
          .objectStore(storeName)
          .put(map, documentRef.path)
          .then((_) {
        return result;
      });
    });
  }

  @override
  DocumentChangeBase documentChange(DocumentChangeType type,
      DocumentSnapshot document, int newIndex, int oldIndex) {
    return DocumentChangeIdb(type, document, newIndex, oldIndex);
  }

  @override
  DocumentSnapshot cloneSnapshot(DocumentSnapshot documentSnapshot) {
    return DocumentSnapshotIdb.fromSnapshot(
        documentSnapshot as DocumentSnapshotIdb);
  }

  @override
  DocumentSnapshot deletedSnapshot(DocumentReference documentReference) {
    return DocumentSnapshotIdb(documentReference, null, null);
  }

  @override
  QuerySnapshot newQuerySnapshot(
      List<DocumentSnapshot> docs, List<DocumentChange> changes) {
    return QuerySnapshotIdb(docs, changes);
  }

  @override
  DocumentSnapshot newSnapshot(
      DocumentReference ref, RecordMetaData meta, DocumentData data) {
    return DocumentSnapshotIdb(ref, meta, data as DocumentDataMap);
  }
}

class LocalTransaction {
  final FirestoreIdb firestoreIdb;
  final idb.Transaction transaction;
  final List<WriteResultIdb> results = [];
  LocalTransaction(this.firestoreIdb, this.transaction);
  Future get completed => transaction.completed;

  void notify() {
    // To use after txtCommit
    for (var result in results) {
      firestoreIdb.notify(result);
    }
  }
}

class TransactionIdb extends WriteBatchIdb implements Transaction {
  final LocalTransaction localTransaction;

  TransactionIdb(FirestoreIdb firestoreIdb, this.localTransaction)
      : super(firestoreIdb);

  @override
  void delete(DocumentReference documentRef) {
    localTransaction.firestoreIdb
        .txnDelete(localTransaction, documentRef as DocumentReferenceIdb);
  }

  @override
  Future<DocumentSnapshot> get(DocumentReference documentRef) async =>
      localTransaction.firestoreIdb
          .txnGet(localTransaction, documentRef as DocumentReferenceIdb);

  @override
  void set(DocumentReference documentRef, Map<String, dynamic> data,
      [SetOptions options]) {
    localTransaction.firestoreIdb.txnSet(localTransaction,
        documentRef as DocumentReferenceIdb, DocumentData(data), options);
  }

  @override
  void update(DocumentReference documentRef, Map<String, dynamic> data) {
    localTransaction.firestoreIdb.txnUpdate(localTransaction,
        documentRef as DocumentReferenceIdb, DocumentData(data));
  }
}

dynamic valueToUpdateValue(dynamic value) {
  if (value == FieldValue.delete) {
    throw 'TODO';
    // return sembast.FieldValue.delete;
  }
  return valueToRecordValue(value, valueToUpdateValue);
}

Map<String, dynamic> documentDataToUpdateMap(DocumentData documentData) {
  if (documentData == null) {
    return null;
  }
  var updateMap = <String, dynamic>{};

  documentDataMap(documentData).map.forEach((String key, value) {
    updateMap[key] = valueToUpdateValue(value);
  });
  return updateMap;
}

class DocumentSnapshotIdb extends DocumentSnapshotBase {
  DocumentSnapshotIdb(
      DocumentReference ref, RecordMetaData meta, DocumentDataMap documentData,
      {bool exists})
      : super(ref, meta, documentData, exists: exists);

  DocumentSnapshotIdb.fromSnapshot(DocumentSnapshotIdb snapshot, {bool exists})
      : this(
          snapshot.ref,
          snapshot.meta,
          snapshot.documentData as DocumentDataMap,
          exists: exists ?? snapshot.exists,
        );
}

class DocumentReferenceIdb implements DocumentReference {
  final FirestoreIdb firestoreIdb;

  @override
  final String path;

  DocumentReferenceIdb(this.firestoreIdb, this.path);

  @override
  CollectionReference collection(String path) =>
      CollectionReferenceIdb(firestoreIdb, url.join(this.path, path));

  @override
  Future delete() => firestoreIdb.deleteDocument(this);

  @override
  Future<DocumentSnapshot> get() async => firestoreIdb.getDocument(this);

  @override
  String get id => url.basename(path);

  @override
  CollectionReference get parent => firestoreIdb.collection(url.dirname(path));

  @override
  Future set(Map<String, dynamic> data, [SetOptions options]) async =>
      firestoreIdb.setDocument(this, DocumentData(data), options);

  @override
  Future update(Map<String, dynamic> data) =>
      firestoreIdb.updateDocument(this, DocumentData(data));

  @override
  Stream<DocumentSnapshot> onSnapshot() => firestoreIdb.onSnapshot(this);
}

class QuerySnapshotIdb extends QuerySnapshotBase {
  QuerySnapshotIdb(
      List<DocumentSnapshot> docs, List<DocumentChange> documentChanges)
      : super(docs, documentChanges);
}

class DocumentChangeIdb extends DocumentChangeBase {
  DocumentChangeIdb(DocumentChangeType type, DocumentSnapshot document,
      int newIndex, int oldIndex)
      : super(type, document, newIndex, oldIndex);
}

class QueryIdb extends FirestoreReferenceBase
    with FirestoreQueryMixin, AttributesMixin
    implements Query {
  FirestoreIdb get firestoreIdb => firestore as FirestoreIdb;

  QueryInfo queryInfo;

  QueryIdb(Firestore firestore, String path) : super(firestore, path);

  @override
  FirestoreQueryMixin clone() =>
      QueryIdb(firestore, path)..queryInfo = queryInfo?.clone();

  @override
  Future<List<DocumentSnapshot>> getCollectionDocuments() async {
    var localTransaction = await firestoreIdb.getReadWriteTransaction();
    var txn = localTransaction.transaction;
    var docs = <DocumentSnapshot>[];
    // We start with the key with the given path
    await txn
        .objectStore(firestoreIdb.storeName)
        .openCursor(range: idb.KeyRange.lowerBound(path), autoAdvance: false)
        .listen((cwv) {
      String docPath = cwv.key;
      if (dirname(docPath) == path) {
        docs.add(firestoreIdb.documentFromRecordMap(firestoreIdb.doc(docPath),
            (cwv.value as Map)?.cast<String, dynamic>()));
        // continue
        cwv.next();
        return;
      }
      // else otherwise just stop
    }).asFuture();
    return docs;
  }
}

class CollectionReferenceIdb extends QueryIdb implements CollectionReference {
  CollectionReferenceIdb(FirestoreIdb firestoreIdb, String path)
      : super(firestoreIdb, path);

  @override
  Future<DocumentReference> add(Map<String, dynamic> data) async =>
      firestoreIdb.add(path, data);

  @override
  DocumentReference doc([String path]) {
    path ??= _generateId();
    return firestore.doc(url.join(this.path, path));
  }

  @override
  DocumentReference get parent {
    String parentPath = this.parentPath;
    if (parentPath == null) {
      return null;
    } else {
      return DocumentReferenceIdb(firestoreIdb, parentPath);
    }
  }
}

class WriteResultIdb extends WriteResultBase {
  WriteResultIdb(String path) : super(path);
}

class WriteBatchIdb extends WriteBatchBase implements WriteBatch {
  final FirestoreIdb firestore;

  WriteBatchIdb(this.firestore);

  Future<List<WriteResultIdb>> txnCommit(LocalTransaction txn) async {
    List<WriteResultIdb> results = [];
    for (var operation in operations) {
      if (operation is WriteBatchOperationDelete) {
        results.add(await firestore.txnDelete(
            txn, operation.docRef as DocumentReferenceIdb));
      } else if (operation is WriteBatchOperationSet) {
        results.add(await firestore.txnSet(
            txn,
            operation.docRef as DocumentReferenceIdb,
            operation.documentData,
            operation.options));
      } else if (operation is WriteBatchOperationUpdate) {
        results.add(await firestore.txnUpdate(txn,
            operation.docRef as DocumentReferenceIdb, operation.documentData));
      } else {
        throw 'not supported $operation';
      }
    }
    return results;
  }

  @override
  Future commit() async {
    var localTransaction = await firestore.getReadWriteTransaction();
    var results = await txnCommit(localTransaction);
    await localTransaction.completed;
    notify(results);
  }

  // To use after txtCommit
  void notify(List<WriteResultIdb> results) {
    for (var result in results) {
      firestore.notify(result);
    }
  }
}

String _generateId() => Uuid().v4().toString();
