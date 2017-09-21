import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:logging/logging.dart' as log;
import 'package:offthechain/offthechain.dart';

/// Service layer functionality for pseudobot
class PseudobotService {

  static final log.Logger _logger = new log.Logger('PseudobotService');
  final Random _random = new Random();

  final RegExp _whiteSpaceRegExp = new RegExp(r"\s+");
  final RegExp _blockQuotesRegExp = new RegExp(r"```[\s\S]+```");
  final RegExp _newlinesRegExp = new RegExp(r"[\r\n]+");
  final RegExp _extraSpacesRegExp = new RegExp(r"\ {2,}");
  final RegExp _emojisRegExp = new RegExp(r':[^ ]+:');
  final RegExp _floatingPunctuationRegExp = new RegExp(r'\s[^A-Za-z0-9]+\s');
  final RegExp _danglingLeftQuotes = new RegExp('(\\s)["\'(\\[]([^"\')\\] ]+?\\s)');
  final RegExp _danglingRightQuotes = new RegExp('(\\s[^"\'(\\[ ]+?)["\')\\]]+([^A-Za-z0-9]+\\s)');


  final String _sentencesBinaryLocation;

  CorpusRepository _corpusRepo;
  MarkovChainService<GramString> _markovChainService;

  /// Instantiates a PseudobotService
  PseudobotService(this._corpusRepo, this._markovChainService, this._sentencesBinaryLocation);

  /// Adds a text message from a user to his Corpus
  Future<dynamic> addTextFromUser(String text, String user) async {

    // Clean up the text
    text = text.replaceAll(_blockQuotesRegExp, "");
    text = text.replaceAll(_newlinesRegExp, "");
    text = text.replaceAll(_emojisRegExp, "");
    text = text.replaceAll(_floatingPunctuationRegExp, "");
    text = text.replaceAllMapped(_danglingLeftQuotes, (Match m) => "${m[1]}${m[2]}");
    text = text.replaceAllMapped(_danglingRightQuotes, (Match m) => "${m[1]}${m[2]}");
    text = text.replaceAll(_extraSpacesRegExp, " ");

    // Can't figure out how to pass the input right to sentences, so let's
    // write it to a file first
    final String filename = "/tmp/pseudobot-slack-import-${_random.nextInt(10000)}";
    final File tmpFile = new File(filename)
      ..writeAsStringSync(text);

    // Now break up the sentences.
    final Process process = await Process.start(_sentencesBinaryLocation,
        <String>["-f", filename]);
    await for (String line in process.stdout.transform(UTF8.decoder)
        .transform(const LineSplitter())) {

      // We only want phrases longer than 3 words
      if (line.split(" ").length <= 3) {
        continue;
      }

      _logger.fine("$user said $line");

      final List<GramString> gramStrings = new List<GramString>();
      line.split(_whiteSpaceRegExp).forEach((String word) {
        final GramString gramString = new GramString(word);
        if (gramString.comparableString != "") {
          gramStrings.add(gramString);
        }
      });

      // Find the corpus
      Corpus corpus = await _corpusRepo.getByName(user);
      if (corpus == null) {
        corpus = new Corpus(user);
        await _corpusRepo.save(<Corpus>[corpus]);
      }

      await _markovChainService.addSequence(gramStrings, corpus);
    }

    if (tmpFile.existsSync()) {
      tmpFile.deleteSync();
    }
  }
}