import 'dart:io';
import 'package:io/io.dart';
import 'package:path/path.dart' as path;
import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';
import 'package:http/http.dart' as http;

import 'setup.dart';

/// Location of the tools configuration file.
///
/// Relative to the project root.
const String configPath = 'tools.yaml';

/// Location of the tools directory.
///
/// Relative to the project root.
const String toolsDirectory = '.tools';

class BinaryInfo {
  final String name;
  final String destination;
  late final Uri url;
  late final String? sha256;

  BinaryInfo({
    required this.name,
    required this.destination,
    required String url,
    String? sha256,
  }) {
    this.url = Uri.parse(url);
    this.sha256 = sha256?.toLowerCase();
  }

  factory BinaryInfo.fromMap(Map map) {
    if (!map.containsKey("name")) {
      throw ArgumentError.value(map, "map", "Should contain 'name'");
    }
    final name = map["name"];
    if (name is! String) {
      throw ArgumentError.value(
        name,
        'map["name"]',
        "Should be String, but is ${name.runtimeType}",
      );
    }

    if (!map.containsKey("destination")) {
      throw ArgumentError.value(map, "map", "Should contain 'destination'");
    }
    final destination = map["destination"];
    if (destination is! String) {
      throw ArgumentError.value(
        destination,
        'map["destination"]',
        "Should be String, but is ${destination.runtimeType}",
      );
    }

    if (!map.containsKey("url")) {
      throw ArgumentError.value(map, "map", "Should contain 'url'");
    }
    final url = map["url"];
    if (url is! String) {
      throw ArgumentError.value(
        url,
        'map["url"]',
        "Should be String, but is ${url.runtimeType}",
      );
    }

    dynamic sha256;
    if (map.containsKey("sha256")) {
      sha256 = map["sha256"];
      if (sha256 is! String?) {
        throw ArgumentError.value(
          sha256,
          'map["sha256"]',
          "Should be String?, but is ${sha256.runtimeType}",
        );
      }
    }

    return BinaryInfo(
      name: name,
      destination: destination,
      url: url,
      sha256: sha256,
    );
  }
}

class DownloadToolsCommand extends SetupCommand {
  @override
  final name = "download-tools";
  @override
  final description =
      "Download and verify tools specified in the configuration file.";

  DownloadToolsCommand() {
    argParser.addFlag(
      'force',
      abbr: 'f',
      help: 'Force re-download of tools, ignoring existing files.',
      negatable: false,
    );
  }

  @override
  Future<ExitCode> run() async {
    logger.i('Downloading tools');

    final configFile = File(configPath);
    if (!await configFile.exists()) {
      logger.e('Configuration file not found at $configPath.');
      return ExitCode.unavailable;
    }

    final config = loadYaml(await configFile.readAsString());
    if (config is! Map) {
      logger.e(
        'Expected tools config to be a map, but got a ${config.runtimeType}',
        error: config,
      );
      return ExitCode.data;
    }
    final binaries = config['binaries'];
    if (binaries is! List) {
      logger.e(
        "Expected 'binaries' in tools config to be a list, but got a ${config.runtimeType}",
        error: binaries,
      );
      return ExitCode.data;
    }
    final binariesInfo = binaries
        .map((dynamic binary) {
          try {
            return BinaryInfo.fromMap(binary);
          } on ArgumentError catch (error) {
            logger.e('Error parsing binary configuration', error: error);
            // Skip this binary if it fails to parse
            return null;
          }
        })
        .nonNulls
        .toList();

    final binariesPath = path.join(toolsDirectory, "bin");
    final binariesDirectory = Directory(binariesPath);
    if (!await binariesDirectory.exists()) {
      logger.i('Creating directory: ${path.absolute(binariesPath)}');
      await binariesDirectory.create(recursive: true);
    }

    final successes = await Future.wait(
      binariesInfo.map(
        (binary) => _downloadBinary(
          binary,
          binariesDirectory,
          forceDownload: argResults!.flag("force"),
        ),
      ),
    );

    if (successes.any((success) => !success)) {
      logger.e('Some tools could not be downloaded or verified.');
      return ExitCode.ioError;
    }

    logger.i('All tools have been downloaded!');
    return ExitCode.success;
  }

  Future<bool> _downloadBinary(
    BinaryInfo binary,
    Directory targetDirectory, {
    bool forceDownload = false,
  }) async {
    logger.i('Downloading ${binary.name} …');

    final destinationPath = path.join(targetDirectory.path, binary.destination);
    final destinationFile = File(destinationPath);

    if (await destinationFile.exists()) {
      if (forceDownload) {
        logger.t(
          '${binary.name} already exists (at $destinationPath), forcing re-download …',
        );
      } else if (binary.sha256 != null && binary.sha256!.isNotEmpty) {
        logger.t(
          '${binary.name} already exists (at $destinationPath), verifying checksum …',
        );
        final actualSha256 = sha256
            .convert(await destinationFile.readAsBytes())
            .toString();
        if (actualSha256 == binary.sha256) {
          logger.i('Checksum verified for ${binary.name}. Skipping download.');
          return true;
        } else {
          logger.t("""
Checksum mismatch for ${binary.name}. Re-downloading …
  Expected: ${binary.sha256}
  Actual:   $actualSha256""");
        }
      } else {
        logger.i(
          '${binary.name} already exists (at $destinationPath), with no checksum to verify. Skipping download.',
        );
        return true;
      }
    }

    logger.t(
      'Downloading ${binary.name} from ${binary.url} to $destinationPath …',
    );

    try {
      final response = await http.get(binary.url);

      if (response.statusCode != 200) {
        logger.w(
          'Failed to download ${binary.name}: HTTP ${response.statusCode} - ${response.reasonPhrase}',
        );
        return false;
      }

      final bytes = response.bodyBytes;

      if (binary.sha256 != null && binary.sha256!.isNotEmpty) {
        final actualSha256 = sha256.convert(bytes).toString();
        if (actualSha256 != binary.sha256) {
          logger.w(
            """
Checksum mismatch for ${binary.name}
  Expected: ${binary.sha256}
  Actual:   $actualSha256
  File will not be saved. Please verify the URL and checksum in $configPath.""",
          );
          return false;
        }
        logger.t('Checksum verified for ${binary.name}');
      }

      await destinationFile.writeAsBytes(bytes);
      logger.i('Succesfully downloaded ${binary.name}.');
      return true;
    } catch (error) {
      logger.e('Error downloading ${binary.name}', error: error);
      // If we partially downloaded the file, attempt to delete it
      if (await destinationFile.exists()) {
        try {
          await destinationFile.delete();
        } catch (_) {}
      }
      return false;
    }
  }
}
