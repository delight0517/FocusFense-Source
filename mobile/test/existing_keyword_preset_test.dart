import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/data/premade_p_block_website_list.dart';
import 'package:six_clean_room/utils/cold_turkey_rule_parser.dart';
import 'package:six_clean_room/utils/url_rule_matcher.dart';

void main() {
  test(
    'existing Google presets match contained Korean terms in encoded URLs',
    () {
      for (final term in <String>['섹시', '엉덩이']) {
        final pattern = '*google.com/*q=*$term*';
        expect(kPBlockWebsiteUrlPatterns, contains(pattern));
        expect(parseColdTurkeyLine(pattern)?.keywordPattern, pattern);
        for (final query in <String>[
          term,
          '앞 $term 뒤',
          '${term}가 포함된 검색어',
          '100% $term',
        ]) {
          final url = Uri.https('www.google.com', '/search', <String, String>{
            'q': query,
          }).toString();
          expect(urlMatchesColdTurkeyPattern(url, pattern), true, reason: url);
        }
        expect(
          urlMatchesColdTurkeyPattern(
            'https://www.google.com/search?q=normal',
            pattern,
          ),
          false,
        );
        expect(
          urlMatchesColdTurkeyPattern(
            'https://example.org/search?q=${Uri.encodeComponent(term)}',
            pattern,
          ),
          false,
        );
      }
    },
  );

  test(
    'specific path rules keep allowed pages and unrelated hosts available',
    () {
      const pattern = 'example.org/private/selected';
      expect(
        urlMatchesColdTurkeyPattern(
          'https://example.org/private/selected?x=1',
          pattern,
        ),
        true,
      );
      expect(
        urlMatchesColdTurkeyPattern('https://example.org/allowed', pattern),
        false,
      );
      expect(
        urlMatchesColdTurkeyPattern(
          'https://other.org/private/selected',
          pattern,
        ),
        false,
      );
    },
  );
}
