import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:logging/logging.dart' as log;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_route/shelf_route.dart';
import 'package:shelf_bind/shelf_bind.dart' as bind;
import 'package:http/http.dart' as http;
import 'package:offthechain/offthechain.dart';
import 'package:slack_pseudobot/slack-pseudobot.dart';

String _googleKeyID;
String _googleKey;
String _clientEmail;
String _clientId;
String _projectId;
String _namespace;
String _sentencesBinaryLocation;

CorpusRepository _corpusRepo;
GramRepository<GramString> _gramRepo;
MarkovChainService<GramString> _markovChainService;
PseudobotService _pseudobotService;

String _botSlackId;
String _botName;
Map<String, String> _channelUrls = new Map<String, String>();
int _serverPort;

final log.Logger _logger = new log.Logger('server');

void main(List<String> args) {

  _getArguments(args);

  log.Logger.root.level = log.Level.FINER;
  log.Logger.root.onRecord.listen((log.LogRecord rec) {
    print('${rec.level.name}: ${rec.time}: ${rec.message}');
  });

  _logger.fine("Starting server");

  // ignore: always_specify_types
  final Router myRouter = router(handlerAdapter: bind.handlerAdapter())
    ..post("/slack", (Map<String, dynamic> map) {
      if (map["type"] == null) {
        return new Response.notFound("I don't understand this request");
      }

      if (map["type"] == "url_verification") {
        return new Response.ok(map["challenge"]);
      } else if (map["type"] == "event_callback" && map["event"]["subtype"] == null) {
        _processMessage(map["event"]["user"], map["event"]["text"],
            map["event"]["channel"]);
        return new Response.ok("OK");
      } else {
        return new Response.forbidden("Not supported");
      }
    });

  io.serve(myRouter.handler, '0.0.0.0', _serverPort);

  ProcessSignal.SIGINT.watch().listen((_) {
    _logger.fine("Exiting gracefully");
    exit(0);
  });
}

Future<dynamic> _processMessage(String user, String text, String channel) async {

  final RegExp findUsersRegex = new RegExp(r"<@([^>]+)>");

  if (user != null && text != null) {
    _logger.finer("$user said $text in $channel");

    // Let's try and find all the usernames mentioned in this message
    final List<String> mentionedUsers = new List<String>();

    bool isBotMentioned = text.contains(_botName);

    findUsersRegex.allMatches(text).forEach((Match m) {
      final String userName = m.group(1);
      if (userName == _botSlackId) {
        isBotMentioned = true;
      } else if(!mentionedUsers.contains(userName)) {
        mentionedUsers.add(userName);
      }
    });

    if (!isBotMentioned) {
      await _pseudobotService.addTextFromUser(text, user);
    }

    if (mentionedUsers.isNotEmpty) {

      final List<String> corpusIds = new List<String>();
      for (String mentionedUser in mentionedUsers) {
        final Corpus corpus = await _corpusRepo.getByName(mentionedUser);
        if (corpus != null) {
          corpusIds.add(corpus.id);
        }
      }

      if (isBotMentioned || corpusIds.isNotEmpty) {
        String message;
        if (isBotMentioned && corpusIds.isEmpty) {
          message = "I don't know anything about <@${mentionedUsers.join(
              "> or <@")}>.";
        } else if (corpusIds.isNotEmpty) {
          try {
            String generatedText =
                (await _markovChainService.getSequence(corpusIds)).join(" ");

            if (isBotMentioned) {
              message =
                  "<@${mentionedUsers.join("> and <@")}> be like \"$generatedText\"";
            } else {
              // Make sure the first character of the generated text is lowercase
              generatedText =
                  "${generatedText[0].toLowerCase()}${generatedText.substring(1)}";
              message =
                  "Hurr durr, I'm <@${mentionedUsers.join("> and <@")}>, $generatedText";
            }
          } catch (e) {
            _logger.severe("CAUGHT EXCEPTION: ${e.toString()}");
            message = "Hurf... hurf... BLEAGHHH: ${e.toString()}";
          }
        }
        _sendMessage(message, channel);
      }
    } else if (isBotMentioned) {
      _sendMessage("You talking to me, <@$user>?", channel);
    }
  }
}

void _sendMessage(String text, String channelId) {

  _logger.finer("Sending message to $channelId: $text");

  http
    .post(_channelUrls[channelId], body: JSON.encode(<String, String>{"text": text}))
    .then((http.Response response) => _logger.finer(response.body));
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
    ..addOption("slack-bot-id")
    ..addOption("slack-bot-name")
    ..addOption("channel-url", allowMultiple: true)
    ..addOption("server-port");

  final ArgResults argResults = argParser.parse(args);

  if (
  argResults["gcloud-key-id"] == null
      || argResults["gcloud-key-file"] == null
      || argResults["gcloud-client-email"] == null
      || argResults["gcloud-client-id"] == null
      || argResults["gcloud-project-id"] == null
      || argResults["gcloud-namespace"] == null
      || argResults["sentences-bin-location"] == null
      || argResults["slack-bot-id"] == null
      || argResults["slack-bot-name"] == null
      || argResults["channel-url"] == null
      || argResults["server-port"] == null
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
  _botSlackId = argResults["slack-bot-id"];
  _botName = argResults["slack-bot-name"];
  _serverPort = int.parse(argResults["server-port"]);

  for (String channelUrlLine in argResults["channel-url"]) {
    final List<String> segments = channelUrlLine.split("@");
    _channelUrls[segments[0]] = segments[1];
  }

  _corpusRepo = new GoogleCloudDatastoreCorpusRepository(_googleKeyID, _googleKey,
      _clientEmail, _clientId, _projectId, _namespace);
  _gramRepo = new GoogleCloudDatastoreGramRepository<GramString>(_googleKeyID,
      _googleKey, _clientEmail, _clientId, _projectId, _namespace);
  _markovChainService = new MarkovChainService<GramString>(_gramRepo);
  _pseudobotService = new PseudobotService(_corpusRepo, _markovChainService,
      _sentencesBinaryLocation);
}
