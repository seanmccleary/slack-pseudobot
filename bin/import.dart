import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:logging/logging.dart' as log;
import 'package:offthechain/offthechain.dart';
import 'package:slack_pseudobot/slack-pseudobot.dart';

String _googleKeyID;
String _googleKey;
String _clientEmail;
String _clientId;
String _projectId;
String _namespace;
String _sentencesBinaryLocation;
String _importFilesDirectory;

CorpusRepository _corpusRepo;
GramRepository<GramString> _gramRepo;
MarkovChainService<GramString> _markovChainService;
PseudobotService _pseudobotService;

Future<dynamic> main(List<String> args) async {

  log.Logger.root.level = log.Level.FINE;
  log.Logger.root.onRecord.listen((log.LogRecord rec) {
    print('${rec.level.name}: ${rec.time}: ${rec.message}');
  });

  _getArguments(args);

  final Directory directory = new Directory(_importFilesDirectory);

  for (FileSystemEntity fse in directory.listSync()) {

    if (fse is! File) {
      continue;
    }

    final File file = fse;
    final String jsonContents = await file.readAsString();
    final List<Map<String, dynamic>> contents = JSON.decode(jsonContents);

    for(Map<String, dynamic> map in contents) {
      if (map["type"] != "message" || map["subtype"] != null) {
        continue;
      }

      final String user = map["user"];
      final String text = map["text"];

      if (user == null || text == null) {
        continue;
      }

      await _pseudobotService.addTextFromUser(text, user);
    }
  }
}

void _getArguments(List<String> args) {
  final ArgParser argParser = new ArgParser()
    ..addOption("gcloud-key-id")
    ..addOption("gcloud-key-file")
    ..addOption("gcloud-client-email")
    ..addOption("gcloud-client-id")
    ..addOption("gcloud-project-id")
    ..addOption("gcloud-namespace")
    ..addOption("sentences-bin-location")
    ..addOption("slack-dump-dir");

  final ArgResults argResults = argParser.parse(args);

  if (
  argResults["gcloud-key-id"] == null
      || argResults["gcloud-key-file"] == null
      || argResults["gcloud-client-email"] == null
      || argResults["gcloud-client-id"] == null
      || argResults["gcloud-project-id"] == null
      || argResults["gcloud-namespace"] == null
      || argResults["sentences-bin-location"] == null
      || argResults["slack-dump-dir"] == null
  ) {
    print("Usage:\n\n${argParser.usage}");
    exit(1);
  }

  _googleKeyID = argResults["gcloud-key-id"];
  _googleKey = new File(argResults["gcloud-key-file"]).readAsStringSync();
  _clientEmail = argResults["gcloud-client-email"];
  _clientId = argResults["gcloud-client-id"];
  _projectId = argResults["gcloud-project-id"];
  _namespace = argResults["gcloud-namespace"];
  _sentencesBinaryLocation = argResults["sentences-bin-location"];
  _importFilesDirectory = argResults["slack-dump-dir"];

  _corpusRepo = new GoogleCloudDatastoreCorpusRepository(_googleKeyID, _googleKey,
      _clientEmail, _clientId, _projectId, _namespace);
  _gramRepo = new GoogleCloudDatastoreGramRepository<GramString>(_googleKeyID,
      _googleKey, _clientEmail, _clientId, _projectId, _namespace);
  _markovChainService = new MarkovChainService<GramString>(_gramRepo);
  _pseudobotService = new PseudobotService(_corpusRepo, _markovChainService,
      _sentencesBinaryLocation);
}