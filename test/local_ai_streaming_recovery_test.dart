import 'package:flutter_test/flutter_test.dart';
import 'package:lib_llama_cpp/lib_llama_cpp.dart';
import 'package:lib_llama_cpp/src/tool_aware_streaming.dart';

void main() {
  test(
    'final chat parser cannot silently erase non-empty assistant text when no tools exist',
    () {
      const raw = '{"fields":{"brand":{"value":"MOXIYES-D","quote":"MOXIYES-D"}}}';
      const command = LlamaGenerateMessagesCommand(
        messages: <LlamaMessage>[
          LlamaMessage(role: 'user', content: 'extract medicine'),
        ],
        maxTokens: 128,
      );

      final responses = streamToolAwareMessageResponses(
        sampled: const <LlamaResponse>[
          LlamaTokenResponse(text: raw, index: 0),
        ],
        command: command,
        // Reproduces a chat-template parser that sampled valid assistant bytes
        // but reports empty message.content at both partial and final stages.
        parseChatOutput: (text, {required isPartial}) =>
            <String, Object?>{
              'message': <String, Object?>{'content': ''},
            },
      ).toList(growable: false);

      final visible = responses
          .whereType<LlamaTokenResponse>()
          .map((response) => response.text)
          .join();

      expect(visible, raw);
      expect(responses.whereType<LlamaErrorResponse>(), isEmpty);
      expect(responses.whereType<LlamaToolCallResponse>(), isEmpty);
    },
  );

  test('normal parsed streaming content is not duplicated by raw recovery', () {
    const raw = '{"reply":"ready","actions":[]}';
    const command = LlamaGenerateMessagesCommand(
      messages: <LlamaMessage>[
        LlamaMessage(role: 'user', content: 'hello'),
      ],
      maxTokens: 64,
    );

    final responses = streamToolAwareMessageResponses(
      sampled: const <LlamaResponse>[
        LlamaTokenResponse(text: raw, index: 0),
      ],
      command: command,
      parseChatOutput: (text, {required isPartial}) =>
          <String, Object?>{
            'message': <String, Object?>{'content': text},
          },
    ).toList(growable: false);

    final visible = responses
        .whereType<LlamaTokenResponse>()
        .map((response) => response.text)
        .join();

    expect(visible, raw);
  });
}
