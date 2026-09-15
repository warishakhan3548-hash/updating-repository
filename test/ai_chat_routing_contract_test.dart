import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('configured AI route owns typed composer before deterministic commands', () {
    final source = File('lib/ui/ai_screen.dart').readAsStringSync();
    final start = source.indexOf('Future<void> _sendComposer() async');
    final end = source.indexOf('Future<void> _runQuickAction', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));

    final sendComposer = source.substring(start, end);
    final aiGate = sendComposer.indexOf('if (_hasAiRoute)');
    final deterministic = sendComposer.indexOf(
      'final localHandler = widget.onLocalCommand;',
    );
    expect(aiGate, greaterThanOrEqualTo(0));
    expect(deterministic, greaterThan(aiGate));
    expect(sendComposer, isNot(contains('isAiConversationFollowUp')));
  });

  test('legacy mutation follow-up parser is removed from conversation parsing', () {
    final source = File('lib/domain/ai_conversation.dart').readAsStringSync();
    expect(source, isNot(contains("import 'app_brain.dart';")));
    expect(source, isNot(contains('isAiConversationFollowUp')));
  });
}
