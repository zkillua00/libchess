#![forbid(unsafe_code)]

use std::{
    collections::{BTreeMap, BTreeSet},
    path::PathBuf,
    sync::{Arc, Mutex, MutexGuard},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use async_trait::async_trait;
use libchess_core::{
    AccessToken, Account, BackendConnection, BackendIcon, BackendKind, BotGame, BotGameOptions,
    BotGameRequest, BotGameTimeControl, BotOpponent, BotOpponentId, BotReplyDelayOptions,
    ColorPreference, ErrorKind, GameExport, GameHistoryEntry, GameHistoryPage, GameHistoryRequest,
    GameId, GameMoveEvaluation, GameReview, GameReviewMove, GameStatus, GameVariant, GameVariantId,
    LibChessError, LiveGame, LiveGameAction, LiveGameCatalogEvent, LiveGameCatalogEventSink,
    LiveGameEvent, LiveGameEventSink, LiveGamePlayer, LiveGameRequest, LiveGameState,
    LiveGameSummary, MoveSubmission, PlatformBackend, PlatformBackendFactory, PlatformCapability,
    PlayerColor, ProviderDescriptor, ProviderId,
};
use tokio::sync::watch;

mod uci;

use uci::{EngineAnalysis, EngineProbe, UciEngine, locate_and_probe};

const ENGINE_MOVE_TIME: Duration = Duration::from_millis(180);
const REVIEW_MOVE_TIME: Duration = Duration::from_millis(30);
const DEFAULT_REPLY_DELAY_MILLIS: u32 = 500;
const MAXIMUM_REPLY_DELAY_MILLIS: u32 = 2_000;
const REPLY_DELAY_STEP_MILLIS: u32 = 100;
const LOCAL_ACCOUNT_ID: &str = "local-player";
const LOCAL_ACCOUNT_NAME: &str = "Local Player";

pub struct StockfishFactory {
    descriptor: ProviderDescriptor,
    executable: Option<PathBuf>,
}

impl Default for StockfishFactory {
    fn default() -> Self {
        let discovery = locate_and_probe();
        let (engine_name, executable, unavailable_reason) = match discovery {
            Ok(EngineProbe { path, name }) => (name, Some(path), None),
            Err(error) => ("Stockfish".to_owned(), None, Some(error.message)),
        };
        Self {
            descriptor: descriptor(engine_name, unavailable_reason.clone()),
            executable,
        }
    }
}

impl PlatformBackendFactory for StockfishFactory {
    fn descriptor(&self) -> &ProviderDescriptor {
        &self.descriptor
    }

    fn create(&self, _token: AccessToken) -> Result<Arc<dyn PlatformBackend>, LibChessError> {
        Err(LibChessError::unsupported(
            "the local Stockfish backend does not accept access tokens",
        ))
    }

    fn create_local(&self) -> Result<Arc<dyn PlatformBackend>, LibChessError> {
        let executable = self.executable.clone().ok_or_else(|| {
            LibChessError::unsupported(
                self.descriptor
                    .unavailable_reason
                    .clone()
                    .unwrap_or_else(|| "Stockfish is unavailable".to_owned()),
            )
        })?;
        Ok(Arc::new(StockfishBackend::new(
            self.descriptor.clone(),
            executable,
        )))
    }
}

fn descriptor(engine_name: String, unavailable_reason: Option<String>) -> ProviderDescriptor {
    let variants = vec![
        GameVariant::new("standard", "Standard", true, false, true)
            .expect("the built-in standard variant is valid"),
        GameVariant::new("from-position", "From Position", true, true, true)
            .expect("the built-in custom-position variant is valid"),
    ];
    let bot_opponents = (0_u8..=20)
        .map(|skill| {
            BotOpponent::new(format!("skill-{skill}"), format!("Skill {skill}"))
                .expect("the built-in Stockfish skill is valid")
        })
        .collect();
    ProviderDescriptor {
        id: ProviderId::new("stockfish").expect("the built-in backend identifier is valid"),
        kind: BackendKind::LocalEngine,
        display_name: engine_name,
        subtitle: "Local UCI chess engine".to_owned(),
        description: "Play private games and run post-game analysis entirely on this Mac. No account or network connection is required."
            .to_owned(),
        icon: BackendIcon::Processor,
        action_title: "Use Local Engine".to_owned(),
        web_url: None,
        connection: BackendConnection::Local,
        available: unavailable_reason.is_none(),
        unavailable_reason,
        capabilities: BTreeSet::from([
            PlatformCapability::Account,
            PlatformCapability::BotGames,
            PlatformCapability::GameHistory,
            PlatformCapability::GameReview,
            PlatformCapability::LocalGames,
            PlatformCapability::LiveGames,
            PlatformCapability::PgnExport,
            PlatformCapability::PositionAnalysis,
            PlatformCapability::RealtimeEvents,
        ]),
        bot_opponents,
        bot_game_options: Some(BotGameOptions {
            variants,
            colors: BTreeSet::from([
                ColorPreference::White,
                ColorPreference::Random,
                ColorPreference::Black,
            ]),
            clock: None,
            correspondence_days: Vec::new(),
            unlimited: true,
            reply_delay: Some(
                BotReplyDelayOptions::new(
                    0,
                    MAXIMUM_REPLY_DELAY_MILLIS,
                    REPLY_DELAY_STEP_MILLIS,
                    DEFAULT_REPLY_DELAY_MILLIS,
                )
                .expect("the built-in reply-delay options are valid"),
            ),
            default_opponent_id: BotOpponentId::new("skill-10")
                .expect("the built-in Stockfish skill is valid"),
            default_variant_id: GameVariantId::new("standard")
                .expect("the built-in variant is valid"),
            default_time_control: BotGameTimeControl::Unlimited,
            default_color: ColorPreference::Random,
        }),
    }
}

struct StockfishBackend {
    descriptor: ProviderDescriptor,
    executable: PathBuf,
    state: Arc<Mutex<BackendState>>,
    catalog: watch::Sender<u64>,
}

impl StockfishBackend {
    fn new(descriptor: ProviderDescriptor, executable: PathBuf) -> Self {
        let (catalog, _) = watch::channel(0);
        Self {
            descriptor,
            executable,
            state: Arc::new(Mutex::new(BackendState::default())),
            catalog,
        }
    }

    fn game(&self, id: &GameId) -> Result<Arc<Mutex<LocalGame>>, LibChessError> {
        lock(&self.state)?
            .games
            .get(id.as_str())
            .cloned()
            .ok_or_else(|| LibChessError::invalid_input(format!("unknown local game '{id}'")))
    }

    fn signal_catalog(&self) {
        let next = self.catalog.borrow().wrapping_add(1);
        self.catalog.send_replace(next);
    }
}

#[async_trait]
impl PlatformBackend for StockfishBackend {
    fn descriptor(&self) -> &ProviderDescriptor {
        &self.descriptor
    }

    async fn account(&self) -> Result<Account, LibChessError> {
        Ok(Account {
            provider: self.descriptor.id.clone(),
            id: LOCAL_ACCOUNT_ID.to_owned(),
            username: LOCAL_ACCOUNT_NAME.to_owned(),
            title: None,
        })
    }

    async fn create_bot_game(&self, request: BotGameRequest) -> Result<BotGame, LibChessError> {
        validate_request(&self.descriptor, &request)?;
        let descriptor = self.descriptor.clone();
        let executable = self.executable.clone();
        let created = tokio::task::spawn_blocking(move || {
            LocalGame::create(&descriptor, executable, request)
        })
        .await
        .map_err(task_error)??;
        let bot_game = created.bot_game.clone();
        lock(&self.state)?
            .games
            .insert(bot_game.id.clone(), Arc::new(Mutex::new(created.game)));
        self.signal_catalog();
        Ok(bot_game)
    }

    async fn watch_live_game(
        &self,
        request: LiveGameRequest,
        events: LiveGameEventSink,
    ) -> Result<(), LibChessError> {
        let game = self.game(&request.game_id)?;
        let mut receiver = lock(&game)?.updates.subscribe();
        let initial = receiver.borrow().clone();
        if initial.player_color != request.player_color {
            return Err(LibChessError::invalid_input(
                "the requested color does not match the local game",
            ));
        }
        events(LiveGameEvent::GameUpdated {
            game: Box::new(initial.clone()),
        });
        if !initial.state.status.is_playable() {
            return Ok(());
        }
        loop {
            receiver.changed().await.map_err(|_| {
                engine_error("the local game event stream ended unexpectedly", true)
            })?;
            let game = receiver.borrow_and_update().clone();
            let finished = !game.state.status.is_playable();
            events(LiveGameEvent::GameUpdated {
                game: Box::new(game),
            });
            if finished {
                return Ok(());
            }
        }
    }

    async fn live_games(&self) -> Result<Vec<LiveGameSummary>, LibChessError> {
        let games = lock(&self.state)?
            .games
            .values()
            .cloned()
            .collect::<Vec<_>>();
        let mut summaries = Vec::new();
        for game in games {
            let game = lock(&game)?;
            if game.live.state.status.is_playable() {
                summaries.push(game.summary());
            }
        }
        Ok(summaries)
    }

    async fn game_history(
        &self,
        request: GameHistoryRequest,
    ) -> Result<GameHistoryPage, LibChessError> {
        if request.account_id != LOCAL_ACCOUNT_ID {
            return Err(LibChessError::invalid_input(
                "the requested history does not belong to the local player",
            ));
        }
        let games = lock(&self.state)?
            .games
            .values()
            .cloned()
            .collect::<Vec<_>>();
        let mut history = games
            .into_iter()
            .map(|game| lock(&game).map(|game| game.history_entry()))
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .filter(|game| !game.status.is_playable())
            .filter(|game| {
                request
                    .before_millis
                    .is_none_or(|before| game.created_at_millis < before)
            })
            .collect::<Vec<_>>();
        history.sort_by_key(|game| std::cmp::Reverse(game.created_at_millis));
        let limit = usize::from(request.limit);
        let has_more = history.len() > limit;
        history.truncate(limit);
        let next_before_millis = has_more
            .then(|| history.last()?.created_at_millis.checked_sub(1))
            .flatten();
        Ok(GameHistoryPage {
            games: history,
            next_before_millis,
        })
    }

    async fn export_game(&self, game_id: GameId) -> Result<GameExport, LibChessError> {
        let game = self.game(&game_id)?;
        let snapshot = lock(&game)?.snapshot();
        tokio::task::spawn_blocking(move || export_snapshot(snapshot))
            .await
            .map_err(task_error)?
    }

    async fn review_game(&self, game_id: GameId) -> Result<GameReview, LibChessError> {
        let game = self.game(&game_id)?;
        let snapshot = lock(&game)?.snapshot();
        let executable = self.executable.clone();
        tokio::task::spawn_blocking(move || review_snapshot(executable, snapshot))
            .await
            .map_err(task_error)?
    }

    async fn watch_live_game_catalog(
        &self,
        events: LiveGameCatalogEventSink,
    ) -> Result<(), LibChessError> {
        let mut receiver = self.catalog.subscribe();
        loop {
            receiver.changed().await.map_err(|_| {
                engine_error("the local game catalog stream ended unexpectedly", true)
            })?;
            receiver.borrow_and_update();
            events(LiveGameCatalogEvent::Changed);
        }
    }

    async fn play_move(&self, submission: MoveSubmission) -> Result<(), LibChessError> {
        let game = self.game(&submission.game_id)?;
        tokio::task::spawn_blocking(move || lock(&game)?.play_player_move(submission))
            .await
            .map_err(task_error)??;
        self.signal_catalog();
        Ok(())
    }

    async fn perform_game_action(
        &self,
        game_id: GameId,
        action: LiveGameAction,
    ) -> Result<(), LibChessError> {
        let game = self.game(&game_id)?;
        tokio::task::spawn_blocking(move || lock(&game)?.perform_action(action))
            .await
            .map_err(task_error)??;
        self.signal_catalog();
        Ok(())
    }
}

#[derive(Default)]
struct BackendState {
    games: BTreeMap<String, Arc<Mutex<LocalGame>>>,
}

struct CreatedGame {
    bot_game: BotGame,
    game: LocalGame,
}

struct LocalGame {
    live: LiveGame,
    opponent: BotOpponent,
    skill: u8,
    created_at_millis: u64,
    last_move_at_millis: u64,
    reply_delay: Duration,
    engine: Option<UciEngine>,
    updates: watch::Sender<LiveGame>,
}

#[derive(Clone)]
struct GameSnapshot {
    live: LiveGame,
}

impl LocalGame {
    fn create(
        descriptor: &ProviderDescriptor,
        executable: PathBuf,
        request: BotGameRequest,
    ) -> Result<CreatedGame, LibChessError> {
        let opponent = descriptor
            .bot_opponents
            .iter()
            .find(|opponent| opponent.id == request.opponent_id)
            .cloned()
            .ok_or_else(|| LibChessError::invalid_input("unknown Stockfish skill"))?;
        let skill = parse_skill(opponent.id.as_str())?;
        let variant = descriptor
            .bot_game_options
            .as_ref()
            .and_then(|options| {
                options
                    .variants
                    .iter()
                    .find(|variant| variant.id == request.variant_id)
            })
            .cloned()
            .ok_or_else(|| LibChessError::invalid_input("unsupported local-game variant"))?;
        let player_color = resolve_color(request.color)?;
        let reply_delay = descriptor
            .bot_game_options
            .as_ref()
            .and_then(|options| options.reply_delay.as_ref())
            .map(|options| {
                Duration::from_millis(u64::from(
                    request.reply_delay_millis.unwrap_or(options.default_millis),
                ))
            })
            .unwrap_or_default();
        let initial_fen = request
            .initial_fen
            .clone()
            .unwrap_or_else(|| "startpos".to_owned());
        let board =
            libchess_rules::reconstruct(variant.id.as_str(), &initial_fen, &request.initial_moves)
                .map_err(|error| {
                    LibChessError::invalid_input(format!("invalid position: {error}"))
                })?;
        let id = random_game_id()?;
        let game_id = GameId::new(id.clone())?;
        let local_player = LiveGamePlayer {
            id: Some(LOCAL_ACCOUNT_ID.to_owned()),
            name: LOCAL_ACCOUNT_NAME.to_owned(),
            title: None,
            rating: None,
            provisional: false,
            ai_level: None,
        };
        let engine_player = LiveGamePlayer {
            id: None,
            name: descriptor.display_name.clone(),
            title: Some("Engine".to_owned()),
            rating: None,
            provisional: false,
            ai_level: Some(skill),
        };
        let (white, black) = match player_color {
            PlayerColor::White => (local_player, engine_player),
            PlayerColor::Black => (engine_player, local_player),
        };
        let now = now_millis();
        let live = LiveGame {
            provider: descriptor.id.clone(),
            id: game_id,
            url: String::new(),
            player_color,
            initial_fen: initial_fen.clone(),
            variant_id: variant.id.clone(),
            variant_name: variant.display_name.clone(),
            rated: false,
            speed: "unlimited".to_owned(),
            clock: None,
            days_per_turn: None,
            white,
            black,
            state: LiveGameState {
                board,
                status: GameStatus::new("started")?,
                winner: None,
                white_time_millis: None,
                black_time_millis: None,
                white_increment_millis: None,
                black_increment_millis: None,
                white_draw_offer: false,
                black_draw_offer: false,
                white_takeback_offer: false,
                black_takeback_offer: false,
                opponent_gone: false,
                claim_win_in_seconds: None,
            },
        };
        let mut engine = UciEngine::launch(&executable)?;
        engine.set_skill(skill)?;
        engine.new_game()?;
        let (updates, _) = watch::channel(live.clone());
        let mut game = Self {
            live,
            opponent: opponent.clone(),
            skill,
            created_at_millis: now,
            last_move_at_millis: now,
            reply_delay,
            engine: Some(engine),
            updates,
        };
        game.update_terminal()?;
        game.play_engine_if_needed(Duration::ZERO)?;
        game.updates.send_replace(game.live.clone());

        Ok(CreatedGame {
            bot_game: BotGame {
                provider: descriptor.id.clone(),
                id,
                url: String::new(),
                player_color,
                opponent,
                variant,
                time_control: request.time_control,
                speed: game.live.speed.clone(),
                is_my_turn: game.live.state.board.turn == player_color,
                initial_fen: request.initial_fen,
            },
            game,
        })
    }

    fn snapshot(&self) -> GameSnapshot {
        GameSnapshot {
            live: self.live.clone(),
        }
    }

    fn summary(&self) -> LiveGameSummary {
        LiveGameSummary {
            provider: self.live.provider.clone(),
            id: self.live.id.clone(),
            url: String::new(),
            player_color: self.live.player_color,
            display_name: self.opponent.display_name.clone(),
            variant_id: self.live.variant_id.clone(),
            variant_name: self.live.variant_name.clone(),
            rated: false,
            speed: self.live.speed.clone(),
            is_my_turn: self.live.state.board.turn == self.live.player_color,
        }
    }

    fn history_entry(&self) -> GameHistoryEntry {
        GameHistoryEntry {
            provider: self.live.provider.clone(),
            id: self.live.id.clone(),
            url: String::new(),
            analysis_url: String::new(),
            player_color: self.live.player_color,
            opponent_name: self.live_engine_name(),
            opponent_title: Some("Engine".to_owned()),
            opponent_rating: None,
            opponent_ai_level: Some(self.skill),
            variant_id: self.live.variant_id.clone(),
            variant_name: self.live.variant_name.clone(),
            rated: false,
            speed: self.live.speed.clone(),
            status: self.live.state.status.clone(),
            winner: self.live.state.winner,
            created_at_millis: self.created_at_millis,
            last_move_at_millis: self.last_move_at_millis,
        }
    }

    fn live_engine_name(&self) -> String {
        match self.live.player_color {
            PlayerColor::White => self.live.black.name.clone(),
            PlayerColor::Black => self.live.white.name.clone(),
        }
    }

    fn play_player_move(&mut self, submission: MoveSubmission) -> Result<(), LibChessError> {
        if !self.live.state.status.is_playable() {
            return Err(LibChessError::invalid_input("the local game has ended"));
        }
        if self.live.state.board.turn != self.live.player_color {
            return Err(LibChessError::invalid_input(
                "it is not the local player's turn",
            ));
        }
        if !self
            .live
            .state
            .board
            .legal_moves
            .iter()
            .any(|chess_move| chess_move.id == submission.move_id)
        {
            return Err(LibChessError::invalid_input("the move is not legal"));
        }

        let original = self.live.clone();
        let result = (|| {
            let mut moves = self.live.state.board.moves.clone();
            moves.push(submission.move_id);
            self.replace_moves(moves)?;
            if submission.offer_draw {
                self.finish("draw", None)?;
            } else {
                self.update_terminal()?;
                self.play_engine_if_needed(self.reply_delay)?;
            }
            Ok(())
        })();
        if let Err(error) = result {
            self.live = original;
            return Err(error);
        }
        self.publish();
        Ok(())
    }

    fn play_engine_if_needed(&mut self, minimum_reply_time: Duration) -> Result<(), LibChessError> {
        let engine_color = opposite(self.live.player_color);
        if !self.live.state.status.is_playable() || self.live.state.board.turn != engine_color {
            return Ok(());
        }
        let reply_started_at = std::time::Instant::now();
        let engine = self
            .engine
            .as_mut()
            .ok_or_else(|| engine_error("the local game engine has stopped", false))?;
        let analysis = engine.analyse(
            &self.live.initial_fen,
            &self.live.state.board.moves,
            ENGINE_MOVE_TIME,
        )?;
        let best_move = analysis.best_move.ok_or_else(|| {
            engine_error(
                "Stockfish did not return a move for a playable position",
                true,
            )
        })?;
        if !self
            .live
            .state
            .board
            .legal_moves
            .iter()
            .any(|chess_move| chess_move.id == best_move)
        {
            return Err(engine_error(
                format!("Stockfish returned the illegal move '{best_move}'"),
                true,
            ));
        }
        std::thread::sleep(minimum_reply_time.saturating_sub(reply_started_at.elapsed()));
        let mut moves = self.live.state.board.moves.clone();
        moves.push(best_move);
        self.replace_moves(moves)?;
        self.update_terminal()
    }

    fn replace_moves(&mut self, moves: Vec<String>) -> Result<(), LibChessError> {
        self.live.state.board = libchess_rules::reconstruct(
            self.live.variant_id.as_str(),
            &self.live.initial_fen,
            &moves,
        )
        .map_err(|error| {
            engine_error(
                format!("could not reconstruct the local game: {error}"),
                false,
            )
        })?;
        self.last_move_at_millis = now_millis();
        Ok(())
    }

    fn update_terminal(&mut self) -> Result<(), LibChessError> {
        if self.live.state.board.legal_moves.is_empty() {
            if self.live.state.board.in_check {
                self.finish("mate", Some(opposite(self.live.state.board.turn)))
            } else {
                self.finish("stalemate", None)
            }
        } else if self.has_insufficient_material()? {
            self.finish("draw", None)
        } else {
            Ok(())
        }
    }

    fn has_insufficient_material(&self) -> Result<bool, LibChessError> {
        libchess_rules::is_insufficient_material(
            self.live.variant_id.as_str(),
            &self.live.initial_fen,
            &self.live.state.board.moves,
        )
        .map_err(|error| {
            engine_error(
                format!("could not evaluate the local draw state: {error}"),
                false,
            )
        })
    }

    fn finish(&mut self, status: &str, winner: Option<PlayerColor>) -> Result<(), LibChessError> {
        self.live.state.status = GameStatus::new(status)?;
        self.live.state.winner = winner;
        self.last_move_at_millis = now_millis();
        self.engine = None;
        Ok(())
    }

    fn perform_action(&mut self, action: LiveGameAction) -> Result<(), LibChessError> {
        if !self.live.state.status.is_playable() {
            return Err(LibChessError::invalid_input("the local game has ended"));
        }
        match action {
            LiveGameAction::Abort => self.finish("aborted", None)?,
            LiveGameAction::Resign => {
                self.finish("resign", Some(opposite(self.live.player_color)))?
            }
            LiveGameAction::OfferDraw | LiveGameAction::AcceptDraw => self.finish("draw", None)?,
            LiveGameAction::ClaimDraw => {
                if !self.has_insufficient_material()? {
                    return Err(LibChessError::invalid_input(
                        "there is no claimable draw in the current position",
                    ));
                }
                self.finish("draw", None)?;
            }
            LiveGameAction::OfferTakeback | LiveGameAction::AcceptTakeback => {
                let mut moves = self.live.state.board.moves.clone();
                if moves.len() < 2 {
                    return Err(LibChessError::invalid_input(
                        "there is not a complete turn to take back",
                    ));
                }
                moves.truncate(moves.len() - 2);
                self.live.state.status = GameStatus::new("started")?;
                self.live.state.winner = None;
                self.replace_moves(moves)?;
                self.play_engine_if_needed(Duration::ZERO)?;
            }
            LiveGameAction::DeclineDraw | LiveGameAction::DeclineTakeback => {}
            LiveGameAction::ClaimVictory => {
                return Err(LibChessError::unsupported(
                    "victory cannot be claimed against a local engine",
                ));
            }
        }
        self.publish();
        Ok(())
    }

    fn publish(&self) {
        self.updates.send_replace(self.live.clone());
    }
}

fn validate_request(
    descriptor: &ProviderDescriptor,
    request: &BotGameRequest,
) -> Result<(), LibChessError> {
    let options = descriptor
        .bot_game_options
        .as_ref()
        .ok_or_else(|| LibChessError::unsupported("local games are unavailable"))?;
    if !descriptor
        .bot_opponents
        .iter()
        .any(|opponent| opponent.id == request.opponent_id)
    {
        return Err(LibChessError::invalid_input("unknown Stockfish skill"));
    }
    let variant = options
        .variants
        .iter()
        .find(|variant| variant.id == request.variant_id)
        .ok_or_else(|| LibChessError::invalid_input("unsupported local-game variant"))?;
    if !options.colors.contains(&request.color) {
        return Err(LibChessError::invalid_input("unsupported player color"));
    }
    if !matches!(request.time_control, BotGameTimeControl::Unlimited) {
        return Err(LibChessError::invalid_input(
            "the local engine currently advertises unlimited games only",
        ));
    }
    match (&options.reply_delay, request.reply_delay_millis) {
        (Some(reply_delay), Some(value)) if !reply_delay.supports(value) => {
            return Err(LibChessError::invalid_input(
                "the local engine reply delay is outside the advertised range",
            ));
        }
        (None, Some(_)) => {
            return Err(LibChessError::invalid_input(
                "the local engine does not advertise a configurable reply delay",
            ));
        }
        _ => {}
    }
    if variant.requires_custom_position && request.initial_fen.is_none() {
        return Err(LibChessError::invalid_input(
            "this variant requires a starting FEN",
        ));
    }
    if request.initial_fen.is_some() && !variant.supports_custom_position {
        return Err(LibChessError::invalid_input(
            "this variant does not support a starting FEN",
        ));
    }
    if !request.initial_moves.is_empty() && request.initial_fen.is_none() {
        return Err(LibChessError::invalid_input(
            "preloaded move history requires a root FEN",
        ));
    }
    if !request.initial_moves.is_empty() && !variant.supports_move_history {
        return Err(LibChessError::invalid_input(
            "this variant does not support preloaded move history",
        ));
    }
    Ok(())
}

fn parse_skill(id: &str) -> Result<u8, LibChessError> {
    let skill = id
        .strip_prefix("skill-")
        .and_then(|value| value.parse::<u8>().ok())
        .filter(|skill| *skill <= 20)
        .ok_or_else(|| LibChessError::invalid_input("invalid Stockfish skill"))?;
    Ok(skill)
}

fn resolve_color(preference: ColorPreference) -> Result<PlayerColor, LibChessError> {
    match preference {
        ColorPreference::White => Ok(PlayerColor::White),
        ColorPreference::Black => Ok(PlayerColor::Black),
        ColorPreference::Random => {
            let mut byte = [0_u8; 1];
            getrandom::fill(&mut byte).map_err(|error| {
                engine_error(
                    format!("could not choose a random player color: {error}"),
                    true,
                )
            })?;
            Ok(if byte[0] & 1 == 0 {
                PlayerColor::White
            } else {
                PlayerColor::Black
            })
        }
    }
}

fn random_game_id() -> Result<String, LibChessError> {
    let mut bytes = [0_u8; 8];
    getrandom::fill(&mut bytes).map_err(|error| {
        engine_error(format!("could not create a game identifier: {error}"), true)
    })?;
    let mut id = String::from("local-");
    for byte in bytes {
        use std::fmt::Write as _;
        write!(id, "{byte:02x}").expect("writing to a String cannot fail");
    }
    Ok(id)
}

fn export_snapshot(snapshot: GameSnapshot) -> Result<GameExport, LibChessError> {
    let sans = libchess_rules::san_moves(
        snapshot.live.variant_id.as_str(),
        &snapshot.live.initial_fen,
        &snapshot.live.state.board.moves,
    )
    .map_err(|error| engine_error(format!("could not export the game: {error}"), false))?;
    let result = game_result(&snapshot.live);
    let mut tags = vec![
        format!(
            "[Event \"Local {} game\"]",
            escape_pgn(&snapshot.live.variant_name)
        ),
        "[Site \"LibChess\"]".to_owned(),
        "[Date \"????.??.??\"]".to_owned(),
        "[Round \"-\"]".to_owned(),
        format!("[White \"{}\"]", escape_pgn(&snapshot.live.white.name)),
        format!("[Black \"{}\"]", escape_pgn(&snapshot.live.black.name)),
        format!("[Result \"{result}\"]"),
    ];
    if snapshot.live.variant_id.as_str() != "standard" {
        tags.push(format!(
            "[Variant \"{}\"]",
            escape_pgn(&snapshot.live.variant_name)
        ));
    }
    if snapshot.live.initial_fen != "startpos" {
        tags.push("[SetUp \"1\"]".to_owned());
        tags.push(format!(
            "[FEN \"{}\"]",
            escape_pgn(&snapshot.live.initial_fen)
        ));
    }
    let moves = if snapshot.live.initial_fen == "startpos" {
        sans.chunks(2)
            .enumerate()
            .map(|(index, turn)| format!("{}. {}", index + 1, turn.join(" ")))
            .collect::<Vec<_>>()
            .join(" ")
    } else {
        sans.join(" ")
    };
    let pgn = format!("{}\n\n{} {}\n", tags.join("\n"), moves, result);
    Ok(GameExport {
        provider: snapshot.live.provider,
        game_id: snapshot.live.id.clone(),
        suggested_filename: format!("{}.pgn", snapshot.live.id),
        pgn,
    })
}

fn review_snapshot(
    executable: PathBuf,
    snapshot: GameSnapshot,
) -> Result<GameReview, LibChessError> {
    let sans = libchess_rules::san_moves(
        snapshot.live.variant_id.as_str(),
        &snapshot.live.initial_fen,
        &snapshot.live.state.board.moves,
    )
    .map_err(|error| engine_error(format!("could not review the game: {error}"), false))?;
    let mut engine = UciEngine::launch(&executable)?;
    engine.set_skill(20)?;
    engine.new_game()?;
    let mut moves = Vec::with_capacity(sans.len());
    let mut review_moves = Vec::with_capacity(sans.len());
    for (index, (san, move_id)) in sans
        .into_iter()
        .zip(snapshot.live.state.board.moves.iter().cloned())
        .enumerate()
    {
        moves.push(move_id.clone());
        let board = libchess_rules::reconstruct(
            snapshot.live.variant_id.as_str(),
            &snapshot.live.initial_fen,
            &moves,
        )
        .map_err(|error| engine_error(format!("could not review the position: {error}"), false))?;
        let analysis = engine.analyse(&snapshot.live.initial_fen, &moves, REVIEW_MOVE_TIME)?;
        review_moves.push(GameReviewMove {
            ply: u32::try_from(index + 1).unwrap_or(u32::MAX),
            san,
            move_id,
            clock_millis: None,
            evaluation: evaluation_from_engine(analysis, board.turn),
        });
    }
    Ok(GameReview {
        provider: snapshot.live.provider,
        game_id: snapshot.live.id,
        variant_id: snapshot.live.variant_id,
        initial_fen: snapshot.live.initial_fen,
        opening: None,
        moves: review_moves,
    })
}

fn evaluation_from_engine(
    mut analysis: EngineAnalysis,
    side_to_move: PlayerColor,
) -> Option<GameMoveEvaluation> {
    if side_to_move == PlayerColor::Black {
        analysis.centipawns = analysis.centipawns.map(|score| -score);
        analysis.mate = analysis.mate.map(|score| -score);
    }
    (analysis.centipawns.is_some() || analysis.mate.is_some()).then_some(GameMoveEvaluation {
        centipawns: analysis.centipawns,
        mate: analysis.mate,
        best_move: analysis.best_move,
        variation: analysis.variation,
        judgment: None,
    })
}

fn game_result(game: &LiveGame) -> &'static str {
    match game.state.winner {
        Some(PlayerColor::White) => "1-0",
        Some(PlayerColor::Black) => "0-1",
        None if game.state.status.is_playable() || game.state.status.as_str() == "aborted" => "*",
        None => "1/2-1/2",
    }
}

fn escape_pgn(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

fn opposite(color: PlayerColor) -> PlayerColor {
    match color {
        PlayerColor::White => PlayerColor::Black,
        PlayerColor::Black => PlayerColor::White,
    }
}

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

fn lock<T>(mutex: &Mutex<T>) -> Result<MutexGuard<'_, T>, LibChessError> {
    mutex
        .lock()
        .map_err(|_| engine_error("the local engine state is unavailable", true))
}

fn task_error(error: tokio::task::JoinError) -> LibChessError {
    engine_error(format!("the local engine task stopped: {error}"), true)
}

fn engine_error(message: impl Into<String>, retryable: bool) -> LibChessError {
    LibChessError::new(ErrorKind::Provider, message, retryable)
}

#[cfg(test)]
mod tests {
    use super::*;

    const KINGS_ONLY_FEN: &str = "8/5k2/8/8/8/8/3K4/8 w - - 0 1";

    fn game_snapshot(status: &str) -> GameSnapshot {
        let descriptor = descriptor("Stockfish 18".to_owned(), None);
        let board = libchess_rules::reconstruct(
            "standard",
            "startpos",
            &["e2e4".to_owned(), "e7e5".to_owned()],
        )
        .expect("position");
        GameSnapshot {
            live: LiveGame {
                provider: descriptor.id,
                id: GameId::new("local-test").expect("game id"),
                url: String::new(),
                player_color: PlayerColor::White,
                initial_fen: "startpos".to_owned(),
                variant_id: GameVariantId::new("standard").expect("variant"),
                variant_name: "Standard".to_owned(),
                rated: false,
                speed: "unlimited".to_owned(),
                clock: None,
                days_per_turn: None,
                white: LiveGamePlayer {
                    id: Some(LOCAL_ACCOUNT_ID.to_owned()),
                    name: LOCAL_ACCOUNT_NAME.to_owned(),
                    title: None,
                    rating: None,
                    provisional: false,
                    ai_level: None,
                },
                black: LiveGamePlayer {
                    id: None,
                    name: "Stockfish 18".to_owned(),
                    title: Some("Engine".to_owned()),
                    rating: None,
                    provisional: false,
                    ai_level: Some(20),
                },
                state: LiveGameState {
                    board,
                    status: GameStatus::new(status).expect("status"),
                    winner: None,
                    white_time_millis: None,
                    black_time_millis: None,
                    white_increment_millis: None,
                    black_increment_millis: None,
                    white_draw_offer: false,
                    black_draw_offer: false,
                    white_takeback_offer: false,
                    black_takeback_offer: false,
                    opponent_gone: false,
                    claim_win_in_seconds: None,
                },
            },
        }
    }

    #[test]
    fn descriptor_advertises_only_implemented_local_options() {
        let descriptor = descriptor("Stockfish 18".to_owned(), None);
        assert_eq!(descriptor.kind, BackendKind::LocalEngine);
        assert!(descriptor.available);
        assert_eq!(descriptor.bot_opponents.len(), 21);
        assert_eq!(
            descriptor
                .bot_game_options
                .as_ref()
                .expect("bot options")
                .variants
                .len(),
            2
        );
        assert!(
            descriptor
                .bot_game_options
                .as_ref()
                .expect("bot options")
                .variants
                .iter()
                .all(|variant| variant.supports_move_history)
        );
        let reply_delay = descriptor
            .bot_game_options
            .as_ref()
            .and_then(|options| options.reply_delay.as_ref())
            .expect("reply-delay options");
        assert_eq!(reply_delay.default_millis, 500);
        assert!(reply_delay.supports(0));
        assert!(reply_delay.supports(2_000));
        assert!(!reply_delay.supports(550));
        assert!(matches!(descriptor.connection, BackendConnection::Local));
    }

    #[test]
    fn rejects_reply_delays_outside_the_advertised_grid() {
        let descriptor = descriptor("Stockfish 18".to_owned(), None);
        let request = BotGameRequest::new(
            "skill-0",
            "standard",
            BotGameTimeControl::Unlimited,
            ColorPreference::White,
            None,
        )
        .and_then(|request| request.with_reply_delay_millis(550))
        .expect("globally bounded reply delay");

        assert!(validate_request(&descriptor, &request).is_err());

        let mut history_without_fen = BotGameRequest::new(
            "skill-0",
            "standard",
            BotGameTimeControl::Unlimited,
            ColorPreference::White,
            None,
        )
        .expect("base request");
        history_without_fen.initial_moves = vec!["e2e4".to_owned()];
        assert!(validate_request(&descriptor, &history_without_fen).is_err());
    }

    #[test]
    fn builds_local_pgn_without_provider_urls() {
        let export = export_snapshot(game_snapshot("started")).expect("PGN export");
        assert!(export.pgn.contains("1. e4 e5 *"));
        assert!(export.suggested_filename.ends_with(".pgn"));
    }

    #[test]
    fn exports_aborted_games_as_unfinished() {
        let export = export_snapshot(game_snapshot("aborted")).expect("PGN export");

        assert!(export.pgn.contains("[Result \"*\"]"));
        assert!(export.pgn.ends_with("1. e4 e5 *\n"));
        assert!(!export.pgn.contains("1/2-1/2"));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn preloads_move_history_and_can_take_it_back() {
        let Ok(probe) = locate_and_probe() else {
            return;
        };
        let descriptor = descriptor(probe.name, None);
        let backend = StockfishBackend::new(descriptor, probe.path);
        let initial_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
        let request = BotGameRequest::new(
            "skill-0",
            "standard",
            BotGameTimeControl::Unlimited,
            ColorPreference::White,
            Some(initial_fen.to_owned()),
        )
        .and_then(|request| request.with_initial_moves(vec!["e2e4".to_owned(), "e7e5".to_owned()]))
        .and_then(|request| request.with_reply_delay_millis(0))
        .expect("local game with move history");
        let created = backend
            .create_bot_game(request)
            .await
            .expect("create local game with history");
        let game_id = GameId::new(created.id.clone()).expect("game id");

        {
            let game = backend.game(&game_id).expect("stored game");
            let game = lock(&game).expect("game state");
            assert_eq!(
                game.live.state.board.moves,
                vec!["e2e4".to_owned(), "e7e5".to_owned()]
            );
            assert_eq!(game.live.state.board.ply, 2);
            assert_eq!(game.live.state.board.turn, PlayerColor::White);
        }

        backend
            .perform_game_action(game_id.clone(), LiveGameAction::OfferTakeback)
            .await
            .expect("take back loaded turn");

        let game = backend.game(&game_id).expect("stored game");
        let game = lock(&game).expect("game state");
        assert!(game.live.state.board.moves.is_empty());
        assert_eq!(game.live.state.board.ply, 0);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn finishing_a_local_game_releases_its_engine_and_preserves_records() {
        let Ok(probe) = locate_and_probe() else {
            return;
        };
        let descriptor = descriptor(probe.name, None);
        let backend = StockfishBackend::new(descriptor, probe.path);
        let request = BotGameRequest::new(
            "skill-0",
            "standard",
            BotGameTimeControl::Unlimited,
            ColorPreference::White,
            None,
        )
        .expect("local-game request");
        let created = backend
            .create_bot_game(request)
            .await
            .expect("create local game");
        let game_id = GameId::new(created.id).expect("game id");

        backend
            .perform_game_action(game_id.clone(), LiveGameAction::Abort)
            .await
            .expect("abort local game");

        {
            let game = backend.game(&game_id).expect("stored game");
            let game = lock(&game).expect("game state");
            assert_eq!(game.live.state.status.as_str(), "aborted");
            assert!(game.engine.is_none());
        }

        let history = backend
            .game_history(
                GameHistoryRequest::new(LOCAL_ACCOUNT_ID, LOCAL_ACCOUNT_NAME, 20, None)
                    .expect("history request"),
            )
            .await
            .expect("local-game history");
        assert_eq!(history.games.len(), 1);
        assert_eq!(history.games[0].status.as_str(), "aborted");

        let export = backend
            .export_game(game_id.clone())
            .await
            .expect("finished-game export");
        assert!(export.pgn.contains("[Result \"*\"]"));

        let review = backend
            .review_game(game_id)
            .await
            .expect("finished-game review");
        assert!(review.moves.is_empty());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn automatically_adjudicates_a_dead_position() {
        let Ok(probe) = locate_and_probe() else {
            return;
        };
        let descriptor = descriptor(probe.name, None);
        let backend = StockfishBackend::new(descriptor, probe.path);
        let request = BotGameRequest::new(
            "skill-0",
            "from-position",
            BotGameTimeControl::Unlimited,
            ColorPreference::White,
            Some(KINGS_ONLY_FEN.to_owned()),
        )
        .expect("kings-only local game");
        let created = backend
            .create_bot_game(request)
            .await
            .expect("create kings-only local game");
        let game = backend
            .game(&GameId::new(created.id).expect("game id"))
            .expect("stored game");
        let game = lock(&game).expect("game state");

        assert!(!game.live.state.board.legal_moves.is_empty());
        assert_eq!(game.live.state.status.as_str(), "draw");
        assert_eq!(game.live.state.winner, None);
        assert!(game.engine.is_none());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn rejects_a_draw_claim_in_a_normal_playable_position() {
        let Ok(probe) = locate_and_probe() else {
            return;
        };
        let descriptor = descriptor(probe.name, None);
        let backend = StockfishBackend::new(descriptor, probe.path);
        let request = BotGameRequest::new(
            "skill-0",
            "standard",
            BotGameTimeControl::Unlimited,
            ColorPreference::White,
            None,
        )
        .expect("normal local game");
        let created = backend
            .create_bot_game(request)
            .await
            .expect("create normal local game");
        let game_id = GameId::new(created.id).expect("game id");

        let error = backend
            .perform_game_action(game_id.clone(), LiveGameAction::ClaimDraw)
            .await
            .expect_err("normal position must not be claimable");
        assert_eq!(error.kind, ErrorKind::InvalidInput);
        assert!(error.message.contains("no claimable draw"));

        let game = backend.game(&game_id).expect("stored game");
        let game = lock(&game).expect("game state");
        assert_eq!(game.live.state.status.as_str(), "started");
        assert_eq!(game.live.state.winner, None);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn accepts_a_draw_claim_for_an_established_dead_position() {
        let Ok(probe) = locate_and_probe() else {
            return;
        };
        let descriptor = descriptor(probe.name, None);
        let backend = StockfishBackend::new(descriptor, probe.path);
        let request = BotGameRequest::new(
            "skill-0",
            "from-position",
            BotGameTimeControl::Unlimited,
            ColorPreference::White,
            Some(KINGS_ONLY_FEN.to_owned()),
        )
        .expect("kings-only local game");
        let created = backend
            .create_bot_game(request)
            .await
            .expect("create kings-only local game");
        let game_id = GameId::new(created.id).expect("game id");

        backend
            .perform_game_action(game_id.clone(), LiveGameAction::ClaimDraw)
            .await
            .expect("dead position is a valid draw");

        let game = backend.game(&game_id).expect("stored game");
        let game = lock(&game).expect("game state");
        assert_eq!(game.live.state.status.as_str(), "draw");
        assert_eq!(game.live.state.winner, None);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn plays_a_complete_local_turn_through_the_installed_uci_engine() {
        let Ok(probe) = locate_and_probe() else {
            return;
        };
        let descriptor = descriptor(probe.name, None);
        let backend = StockfishBackend::new(descriptor, probe.path);
        let request = BotGameRequest::new(
            "skill-0",
            "standard",
            BotGameTimeControl::Unlimited,
            ColorPreference::White,
            None,
        )
        .expect("local-game request");
        let created = backend
            .create_bot_game(request)
            .await
            .expect("create local game");
        let reply_started_at = std::time::Instant::now();
        backend
            .play_move(MoveSubmission::new(&created.id, "e2e4", false).expect("legal player move"))
            .await
            .expect("play local turn");
        assert!(reply_started_at.elapsed() >= Duration::from_millis(450));

        {
            let game = backend
                .game(&GameId::new(created.id).expect("game id"))
                .expect("stored game");
            let game = lock(&game).expect("game state");
            assert_eq!(
                game.live.state.board.moves.first().map(String::as_str),
                Some("e2e4")
            );
            assert_eq!(game.live.state.board.moves.len(), 2);
            assert_eq!(game.live.state.board.turn, PlayerColor::White);
        }

        let black_game = backend
            .create_bot_game(
                BotGameRequest::new(
                    "skill-0",
                    "standard",
                    BotGameTimeControl::Unlimited,
                    ColorPreference::Black,
                    None,
                )
                .expect("black local-game request"),
            )
            .await
            .expect("create black local game");
        let black_game = backend
            .game(&GameId::new(black_game.id).expect("black game id"))
            .expect("stored black game");
        let black_game = lock(&black_game).expect("black game state");
        assert_eq!(black_game.live.state.board.moves.len(), 1);
        assert_eq!(black_game.live.state.board.turn, PlayerColor::Black);
        assert_eq!(black_game.live.player_color, PlayerColor::Black);
    }
}
