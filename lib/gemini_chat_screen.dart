import 'dart:async';

import 'package:cross_cache/cross_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' hide InMemoryChatController;
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flyer_chat_image_message/flyer_chat_image_message.dart';
import 'package:flyer_chat_text_message/flyer_chat_text_message.dart';
import 'package:flyer_chat_text_stream_message/flyer_chat_text_stream_message.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import 'gemini_stream_manager.dart';
import 'in_memory_chat_controller.dart';

// ─── Constants ────────────────────────────────────────────────────────────────

/// Duration used for the animated text chunk reveal in stream messages.
const Duration _kChunkAnimationDuration = Duration(milliseconds: 350);

// ─── GeminiChatScreen ─────────────────────────────────────────────────────────

class GeminiChatScreen extends StatefulWidget {
  const GeminiChatScreen({super.key, required this.geminiApiKey});

  final String geminiApiKey;

  @override
  State<GeminiChatScreen> createState() => _GeminiChatScreenState();
}

class _GeminiChatScreenState extends State<GeminiChatScreen> {
  // ─── Core dependencies ──────────────────────────────────────────────────

  final _uuid = const Uuid();
  final _crossCache = CrossCache();
  final _scrollController = ScrollController();
  final _chatController = InMemoryChatController();

  // ─── Users ──────────────────────────────────────────────────────────────

  final _currentUser = const User(id: 'me');
  final _agent = const User(id: 'agent');

  // ─── Gemini AI ──────────────────────────────────────────────────────────

  late final GenerativeModel _model;
  late ChatSession _chatSession;
  late final GeminiStreamManager _streamManager;

  // ─── Stream state ───────────────────────────────────────────────────────

  bool _isStreaming = false;
  StreamSubscription? _currentStreamSubscription;
  String? _currentStreamId;

  // ─── Scroll state ───────────────────────────────────────────────────────

  /// When true, the list is locked to the bottom and new content auto-scrolls.
  /// Set to false the moment the user scrolls up manually.
  bool _autoScroll = true;

  // ─── Lifecycle ──────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    _scrollController.addListener(_onUserScroll);

    _streamManager = GeminiStreamManager(
      chatController: _chatController,
      chunkAnimationDuration: _kChunkAnimationDuration,
    );

    _model = GenerativeModel(
      model: 'gemini-2.5-flash-lite',
      apiKey: widget.geminiApiKey,
      safetySettings: [
        SafetySetting(HarmCategory.dangerousContent, HarmBlockThreshold.none),
      ],
    );

    _chatSession = _model.startChat();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onUserScroll);
    _currentStreamSubscription?.cancel();
    _streamManager.dispose();
    _chatController.dispose();
    _scrollController.dispose();
    _crossCache.dispose();
    super.dispose();
  }

  // ─── Scroll ─────────────────────────────────────────────────────────────

  /// Disables auto-scroll as soon as the user manually scrolls upward.
  void _onUserScroll() {
    if (!_scrollController.hasClients) return;

    final isScrollingUp =
        _scrollController.position.userScrollDirection == ScrollDirection.reverse;

    if (isScrollingUp && _autoScroll) {
      setState(() => _autoScroll = false);
    }
  }

  /// Immediately jumps the list to the very bottom.
  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  /// Re-enables auto-scroll and snaps to the bottom on the next frame.
  void _resumeAutoScroll() {
    setState(() => _autoScroll = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  // ─── Stream control ─────────────────────────────────────────────────────

  /// Cancels the active response stream and marks it as stopped.
  void _stopCurrentStream() {
    if (_currentStreamSubscription == null || _currentStreamId == null) return;

    _currentStreamSubscription!.cancel();
    _currentStreamSubscription = null;

    _streamManager.errorStream(_currentStreamId!, 'Stream stopped by user');
    _currentStreamId = null;

    setState(() => _isStreaming = false);
  }

  /// Handles any error that occurs during streaming and cleans up state.
  void _handleStreamError(
    String streamId,
    dynamic error,
    TextStreamMessage? streamMessage,
  ) async {
    debugPrint('[GeminiChat] Stream error ($streamId): $error');

    if (streamMessage != null) {
      await _streamManager.errorStream(streamId, error);
    }

    _currentStreamSubscription = null;
    _currentStreamId = null;

    if (mounted) setState(() => _isStreaming = false);
  }

  // ─── Message handling ───────────────────────────────────────────────────

  /// Called when the user submits a plain-text message from the composer.
  void _handleMessageSend(String text) async {
    _resumeAutoScroll();

    await _chatController.insertMessage(
      TextMessage(
        id: _uuid.v4(),
        authorId: _currentUser.id,
        createdAt: DateTime.now().toUtc(),
        text: text,
        metadata: isOnlyEmoji(text) ? {'isOnlyEmoji': true} : null,
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    _sendContentToGemini(Content.text(text));
  }

  /// Called when the user picks an image from the gallery.
  void _handleAttachmentTap() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;

    await _crossCache.downloadAndSave(image.path);
    await _chatController.insertMessage(
      ImageMessage(
        id: _uuid.v4(),
        authorId: _currentUser.id,
        createdAt: DateTime.now().toUtc(),
        source: image.path,
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    final bytes = await _crossCache.get(image.path);
    _sendContentToGemini(Content.data('image/jpeg', bytes));
  }

  /// Sends [content] to Gemini and streams the response into the chat.
  void _sendContentToGemini(Content content) async {
    _resumeAutoScroll();

    final streamId = _uuid.v4();
    _currentStreamId = streamId;

    TextStreamMessage? streamMessage;
    var messageInserted = false;

    setState(() => _isStreaming = true);

    // Lazily creates and inserts the agent's stream bubble on first chunk.
    Future<void> insertAgentBubble() async {
      if (messageInserted || !mounted) return;
      messageInserted = true;

      streamMessage = TextStreamMessage(
        id: streamId,
        authorId: _agent.id,
        createdAt: DateTime.now().toUtc(),
        streamId: streamId,
      );

      await _chatController.insertMessage(streamMessage!);
      _streamManager.startStream(streamId, streamMessage!);

      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }

    try {
      final response = _chatSession.sendMessageStream(content);

      _currentStreamSubscription = response.listen(
        // ─── Chunk received ───────────────────────────────────────────────
        (chunk) async {
          final text = chunk.text;
          if (text == null || text.isEmpty) return;

          if (!messageInserted) await insertAgentBubble();
          if (streamMessage == null) return;

          _streamManager.addChunk(streamId, text);

          if (_autoScroll) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_autoScroll && _scrollController.hasClients) {
                _scrollToBottom();
              }
            });
          }
        },

        // ─── Stream complete ──────────────────────────────────────────────
        onDone: () async {
          if (streamMessage != null) {
            await _streamManager.completeStream(streamId);
          }

          _currentStreamSubscription = null;
          _currentStreamId = null;

          if (mounted) setState(() => _isStreaming = false);

          // Release auto-scroll lock so the user can freely scroll after.
          setState(() => _autoScroll = false);
        },

        onError: (error) => _handleStreamError(streamId, error, streamMessage),
      );
    } catch (error) {
      _handleStreamError(streamId, error, streamMessage);
    }
  }

  // ─── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(title: const Text('Gemini Chat')),
      body: ChangeNotifierProvider.value(
        value: _streamManager,
        child: Chat(
          chatController: _chatController,
          crossCache: _crossCache,
          currentUserId: _currentUser.id,
          onAttachmentTap: _handleAttachmentTap,
          onMessageSend: _handleMessageSend,
          theme: ChatTheme.fromThemeData(theme),
          resolveUser: (id) => Future.value(
            switch (id) {
              'me' => _currentUser,
              'agent' => _agent,
              _ => null,
            },
          ),
          builders: Builders(
            chatAnimatedListBuilder: (context, itemBuilder) {
              return ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  physics: _autoScroll
                      ? const NeverScrollableScrollPhysics()
                      : const BouncingScrollPhysics(),
                ),
                child: ChatAnimatedList(
                  scrollController: _scrollController,
                  itemBuilder: itemBuilder,
                ),
              );
            },
            imageMessageBuilder: _buildImageMessage,
            textMessageBuilder: _buildTextMessage,
            textStreamMessageBuilder: _buildStreamMessage,
            composerBuilder: _buildComposer,
          ),
        ),
      ),
    );
  }

  // ─── Builder helpers ────────────────────────────────────────────────────

  Widget _buildImageMessage(
    BuildContext context,
    ImageMessage message,
    int index, {
    required bool isSentByMe,
    MessageGroupStatus? groupStatus,
  }) {
    return FlyerChatImageMessage(
      message: message,
      index: index,
      showTime: false,
      showStatus: false,
    );
  }

  Widget _buildTextMessage(
    BuildContext context,
    TextMessage message,
    int index, {
    required bool isSentByMe,
    MessageGroupStatus? groupStatus,
  }) {
    final isAgent = message.authorId == _agent.id;

    return FlyerChatTextMessage(
      message: message,
      index: index,
      showTime: false,
      showStatus: false,
      receivedBackgroundColor: Colors.transparent,
      padding: isAgent
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    );
  }

  Widget _buildStreamMessage(
    BuildContext context,
    TextStreamMessage message,
    int index, {
    required bool isSentByMe,
    MessageGroupStatus? groupStatus,
  }) {
    final isAgent = message.authorId == _agent.id;
    final streamState = context
        .watch<GeminiStreamManager>()
        .getState(message.streamId);

    return FlyerChatTextStreamMessage(
      message: message,
      index: index,
      streamState: streamState,
      chunkAnimationDuration: _kChunkAnimationDuration,
      showTime: false,
      showStatus: false,
      receivedBackgroundColor: Colors.transparent,
      padding: isAgent
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    );
  }

  Widget _buildComposer(BuildContext context) {
    return _Composer(
      isStreaming: _isStreaming,
      onStop: _stopCurrentStream,
    );
  }
}

// ─── _Composer ────────────────────────────────────────────────────────────────

class _Composer extends StatefulWidget {
  const _Composer({
    this.isStreaming = false,
    this.onStop,
  });

  final bool isStreaming;
  final VoidCallback? onStop;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _composerKey = GlobalKey();
  late final TextEditingController _textController;
  late final FocusNode _focusNode;

  bool _hasText = false;

  @override
  void initState() {
    super.initState();

    _textController = TextEditingController();
    _focusNode = FocusNode();

    _textController.addListener(_onTextChanged);
    _focusNode.onKeyEvent = _handlePhysicalKeyboard;

    WidgetsBinding.instance.addPostFrameCallback((_) => _reportComposerHeight());
  }

  @override
  void didUpdateWidget(covariant _Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportComposerHeight());
  }

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ─── Listeners ────────────────────────────────────────────────────────

  void _onTextChanged() {
    final hasText = _textController.text.isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  /// On physical keyboards: Enter sends; Shift+Enter inserts a newline.
  KeyEventResult _handlePhysicalKeyboard(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter) return KeyEventResult.ignored;

    if (HardwareKeyboard.instance.isShiftPressed) {
      // Let the TextField handle Shift+Enter as a newline naturally.
      return KeyEventResult.ignored;
    }

    _submitMessage(_textController.text);
    return KeyEventResult.handled;
  }

  // ─── Height reporting ─────────────────────────────────────────────────

  /// Measures the composer height and reports it to [ComposerHeightNotifier]
  /// so the chat list can correctly offset its bottom padding.
  void _reportComposerHeight() {
    if (!mounted) return;

    final renderBox = _composerKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final height = renderBox.size.height;
    final safeAreaBottom = MediaQuery.of(context).padding.bottom;

    context.read<ComposerHeightNotifier>().setHeight(height - safeAreaBottom);
  }

  // ─── Submit ───────────────────────────────────────────────────────────

  void _submitMessage(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    context.read<OnMessageSendCallback?>()?.call(trimmed);
    _textController.clear();

    // Keep focus so the user can immediately type their next message.
    _focusNode.requestFocus();
  }

  // ─── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final safeAreaBottom = MediaQuery.of(context).padding.bottom;
    final onAttachmentTap = context.read<OnAttachmentTapCallback?>();

    final theme = context.select(
      (ChatTheme t) => (
        bodyMedium: t.typography.bodyMedium,
        onSurface: t.colors.onSurface,
        surfaceContainerHigh: t.colors.surfaceContainerHigh,
        surfaceContainerLow: t.colors.surfaceContainerLow,
      ),
    );

    final bool canSend = widget.isStreaming || _hasText;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: ClipRect(
        child: Container(
          key: _composerKey,
          color: theme.surfaceContainerLow,
          child: Padding(
            padding: EdgeInsets.only(bottom: safeAreaBottom)
                .add(const EdgeInsets.all(8)),
            child: Row(
              children: [
                // ─── Attachment button ───────────────────────────────────
                if (onAttachmentTap != null)
                  IconButton(
                    icon: const Icon(Icons.attachment),
                    color: theme.onSurface.withValues(alpha: 0.5),
                    // Disabled during streaming to prevent interleaved requests.
                    onPressed: widget.isStreaming ? null : onAttachmentTap,
                  )
                else
                  const SizedBox.shrink(),

                const SizedBox(width: 8),

                // ─── Text input ──────────────────────────────────────────
                Expanded(
                  child: TextField(
                    controller: _textController,
                    focusNode: _focusNode,
                    minLines: 1,
                    maxLines: 3,
                    autocorrect: true,
                    autofocus: false,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.newline,
                    // Dim input while the agent is responding.
                    enabled: !widget.isStreaming,
                    onSubmitted: widget.isStreaming ? null : _submitMessage,
                    style: theme.bodyMedium.copyWith(color: theme.onSurface),
                    decoration: InputDecoration(
                      hintText: widget.isStreaming ? 'Responding…' : 'Type a message',
                      hintStyle: theme.bodyMedium.copyWith(
                        color: theme.onSurface.withValues(alpha: 0.5),
                      ),
                      filled: true,
                      fillColor: theme.surfaceContainerHigh.withValues(alpha: 0.8),
                      hoverColor: Colors.transparent,
                      border: const OutlineInputBorder(
                        borderSide: BorderSide.none,
                        borderRadius: BorderRadius.all(Radius.circular(24)),
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: 8),

                // ─── Send / Stop button ──────────────────────────────────
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, animation) =>
                      ScaleTransition(scale: animation, child: child),
                  child: IconButton(
                    key: ValueKey(widget.isStreaming),
                    icon: Icon(
                      widget.isStreaming ? Icons.stop_circle : Icons.send,
                    ),
                    color: canSend
                        ? theme.onSurface.withValues(alpha: 0.85)
                        : theme.onSurface.withValues(alpha: 0.3),
                    onPressed: widget.isStreaming
                        ? widget.onStop
                        : (canSend ? () => _submitMessage(_textController.text) : null),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}