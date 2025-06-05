import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:logger/logger.dart';
import 'package:io/io.dart';

import 'download_tools.dart';

final logFilter = ProductionFilter();
final logPrinter = PrettyPrinter(methodCount: 0);

final logger = Logger(
  filter: logFilter,
  printer: logPrinter,
  level: Level.info,
);

class SetupCommandRunner extends CommandRunner<ExitCode> {
  SetupCommandRunner()
    : super("dart run scripts/setup.dart", "Setup script for the project") {
    argParser
      ..addOption(
        "level",
        abbr: 'l',
        help: "Set the logging level.",
        allowed:
            (Level.values
                    .asNameMap()
                    .entries
                    .where((level) => level.value.value % 1000 == 0)
                    .toList()
                  ..sort((a, b) => a.value.value.compareTo(b.value.value)))
                .map((entry) => entry.key),
      )
      ..addFlag("quiet", abbr: "q", help: "Log only errors.", negatable: false);

    addCommand(DownloadToolsCommand());
  }

  @override
  Future<ExitCode?> run(Iterable<String> arguments) => Future.sync(() async {
    try {
      var parsedArguments = parse(arguments);

      if (parsedArguments.wasParsed("quiet")) {
        // We respect quiet no matter whether the level was set
        logFilter.level = Level.error;
      } else if (parsedArguments.wasParsed("level")) {
        logFilter.level = Level.values.byName(parsedArguments.option("level")!);
      }

      if (parsedArguments.command == null && parsedArguments.rest.isEmpty) {
        if (parsedArguments.flag("help")) {
          printUsage();
          return ExitCode.success;
        }

        // If no command was specified, run the download tools command
        parsedArguments = parse(["download-tools", ...arguments]);
      }

      return await runCommand(parsedArguments);
    } on UsageException catch (error) {
      logger.e(error);
      return ExitCode.usage;
    }
  });

  @override
  void printUsage() => logger.i(usage);
}

abstract class SetupCommand extends Command<ExitCode> {
  @override
  void printUsage() {
    logger.i(usage);
  }
}

void main(List<String> arguments) => SetupCommandRunner()
    .run(arguments)
    .then((code) => exit((code ?? ExitCode.success).code));
