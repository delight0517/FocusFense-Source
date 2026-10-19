import 'dart:convert';
import 'dart:io';

import '../lib/utils/cold_turkey_rule_parser.dart';

/// Convert a Cold Turkey style text export into checked-in preset data.
/// Usage: dart tools/Generate-PBlockPreset.dart input.txt output.dart
Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart tools/Generate-PBlockPreset.dart input.txt output.dart',
    );
    exitCode = 64;
    return;
  }

  final File input = File(args[0]);
  final List<String> sourceLines = await input.readAsLines();
  final List<String> normalizedLines = <String>[];
  int repairedMarkdownLines = 0;
  int skippedRedundantLines = 0;
  for (final String raw in sourceLines) {
    String line = raw.trim().replaceAll('`', '');
    if (line.startsWith('hitomi.la)*hdhd*')) {
      // A damaged concatenation; every site token in it has its own rule.
      skippedRedundantLines++;
      continue;
    }
    final int markdownTail = line.indexOf('](');
    if (line.contains('*[') && markdownTail > 0) {
      final int linkStart = line.indexOf('*[');
      final String first = line
          .substring(0, linkStart)
          .replaceFirst(RegExp(r'[/)\*]+$'), '');
      final String second = line
          .substring(linkStart + 2, markdownTail)
          .replaceAll('/', '')
          .trim();
      if (first.isNotEmpty) normalizedLines.add(first);
      if (second.isNotEmpty) normalizedLines.add(second);
      repairedMarkdownLines++;
      continue;
    }
    if (markdownTail >= 0) {
      line = line.substring(0, markdownTail).trim();
      repairedMarkdownLines++;
    }
    if (line.endsWith('/)*')) {
      line = line.substring(0, line.length - 3);
      repairedMarkdownLines++;
    }
    if (line.isNotEmpty) normalizedLines.add(line);
  }

  final ColdTurkeyImportBatch batch = parseColdTurkeyLines(normalizedLines);
  final List<String> domains = batch.rules
      .where(
        (ColdTurkeyParsedRule rule) => rule.kind == ColdTurkeyRuleKind.domain,
      )
      .map((ColdTurkeyParsedRule rule) => rule.domainHost!)
      .toList();
  final List<String> patterns = batch.rules
      .where(
        (ColdTurkeyParsedRule rule) =>
            rule.kind == ColdTurkeyRuleKind.path ||
            rule.kind == ColdTurkeyRuleKind.urlPattern,
      )
      .map((ColdTurkeyParsedRule rule) => rule.keywordPattern!)
      .toList();
  final RegExp validDomain = RegExp(
    r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$',
    caseSensitive: false,
  );
  final List<String> validDomains = <String>[];
  for (final String domain in domains) {
    if (validDomain.hasMatch(domain)) {
      validDomains.add(domain);
    } else {
      // Preserve malformed/special hosts as extension URL patterns rather
      // than sending invalid host syntax to DNS/hosts enforcement.
      patterns.add(domain);
    }
  }
  final List<String> uniquePatterns = patterns.toSet().toList();

  String dartList(String name, List<String> values) =>
      'const List<String> $name = <String>[\n'
      '${values.map((String value) => '  ${jsonEncode(value)},\n').join()}'
      '];\n';

  final String output =
      '// Generated from the user-provided P Block list.\n'
      '// Keep the source list separately; regenerate with Generate-PBlockPreset.dart.\n\n'
      '${dartList('kPBlockWebsiteDomains', validDomains)}\n'
      '${dartList('kPBlockWebsiteUrlPatterns', uniquePatterns)}';
  await File(args[1]).writeAsString(output, flush: true);
  stdout.writeln(
    'Generated ${validDomains.length} domains and ${uniquePatterns.length} URL patterns '
    '(${batch.rules.length} deduplicated source rules; repaired $repairedMarkdownLines '
    'markdown lines; skipped $skippedRedundantLines damaged duplicate; '
    '${input.lengthSync()} source bytes).',
  );
}
