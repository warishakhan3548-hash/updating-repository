# Simple Local AI connections

The AI connections page now uses `LocalAiService` as the single setup-state authority. A downloaded model is automatically verified, loaded, tested, and only then becomes **Ready**. The green Ready mark requires an active model whose on-device setup checks passed; merely having a GGUF file on disk is insufficient.

The page keeps model search, public catalogue sorting, verified/resumable downloads, device import, activation, removal, Aaris Default AI, scan-review routing, external-AI TXT/JSON flow, and API-provider setup. Advanced model controls stay collapsed until requested. API fields also stay collapsed until requested. No duplicate model controller or overlay state machine was added.
