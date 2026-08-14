use std::{
    collections::BTreeSet,
    io::{BufRead, BufReader, BufWriter, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc::{self, Receiver, RecvTimeoutError},
    thread,
    time::{Duration, Instant},
};

use libchess_core::{ErrorKind, LibChessError};

const STARTUP_TIMEOUT: Duration = Duration::from_secs(5);
const READY_TIMEOUT: Duration = Duration::from_secs(3);
const SEARCH_GRACE: Duration = Duration::from_secs(2);

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct EngineProbe {
    pub path: PathBuf,
    pub name: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct EngineAnalysis {
    pub best_move: Option<String>,
    pub centipawns: Option<i32>,
    pub mate: Option<i32>,
    pub variation: Option<String>,
}

pub(crate) fn locate_and_probe() -> Result<EngineProbe, LibChessError> {
    let mut candidates = Vec::new();
    if let Some(path) = std::env::var_os("LIBCHESS_STOCKFISH") {
        candidates.push(PathBuf::from(path));
    }
    if let Some(paths) = std::env::var_os("PATH") {
        candidates.extend(std::env::split_paths(&paths).map(|path| path.join("stockfish")));
    }
    candidates.extend(
        [
            "/opt/homebrew/bin/stockfish",
            "/usr/local/bin/stockfish",
            "/opt/local/bin/stockfish",
            "/usr/bin/stockfish",
        ]
        .map(PathBuf::from),
    );
    let mut seen = BTreeSet::new();
    candidates.retain(|path| seen.insert(path.clone()));

    let mut failures = Vec::new();
    for path in candidates {
        if !path.is_file() {
            continue;
        }
        match UciEngine::launch(&path) {
            Ok(engine) => {
                let probe = EngineProbe {
                    path,
                    name: engine.name.clone(),
                };
                drop(engine);
                return Ok(probe);
            }
            Err(error) => failures.push(format!("{}: {}", path.display(), error.message)),
        }
    }

    let detail = if failures.is_empty() {
        "Stockfish was not found. Install it or set LIBCHESS_STOCKFISH to the engine executable."
            .to_owned()
    } else {
        format!(
            "Stockfish was found but could not be started: {}",
            failures.join("; ")
        )
    };
    Err(engine_error(detail, false))
}

pub(crate) struct UciEngine {
    child: Child,
    input: BufWriter<ChildStdin>,
    output: Receiver<String>,
    pub name: String,
}

fn stop_child(child: &mut Child) {
    if child.try_wait().ok().flatten().is_none() {
        let _ = child.kill();
    }
    let _ = child.wait();
}

impl UciEngine {
    pub fn launch(path: &Path) -> Result<Self, LibChessError> {
        let mut child = Command::new(path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|error| {
                engine_error(
                    format!("could not start '{}': {error}", path.display()),
                    false,
                )
            })?;
        let Some(input) = child.stdin.take() else {
            stop_child(&mut child);
            return Err(engine_error(
                "Stockfish did not expose standard input",
                false,
            ));
        };
        let Some(output) = child.stdout.take() else {
            stop_child(&mut child);
            return Err(engine_error(
                "Stockfish did not expose standard output",
                false,
            ));
        };
        let (sender, receiver) = mpsc::channel();
        if let Err(error) = thread::Builder::new()
            .name("libchess-stockfish-output".to_owned())
            .spawn(move || {
                for line in BufReader::new(output).lines() {
                    let Ok(line) = line else { break };
                    if sender.send(line).is_err() {
                        break;
                    }
                }
            })
        {
            stop_child(&mut child);
            return Err(engine_error(
                format!("could not create the Stockfish output reader: {error}"),
                false,
            ));
        }

        let mut engine = Self {
            child,
            input: BufWriter::new(input),
            output: receiver,
            name: "Stockfish".to_owned(),
        };
        engine.send("uci")?;
        let deadline = Instant::now() + STARTUP_TIMEOUT;
        loop {
            let line = engine.receive_until(deadline, "the UCI handshake")?;
            if let Some(name) = line.strip_prefix("id name ") {
                let name = name.trim();
                if !name.is_empty() && name.len() <= 128 && !name.chars().any(char::is_control) {
                    engine.name = name.to_owned();
                }
            }
            if line == "uciok" {
                break;
            }
        }
        engine.send("setoption name Threads value 1")?;
        engine.send("setoption name Hash value 16")?;
        engine.send("setoption name Ponder value false")?;
        engine.ready()?;
        Ok(engine)
    }

    pub fn set_skill(&mut self, skill: u8) -> Result<(), LibChessError> {
        if skill > 20 {
            return Err(LibChessError::invalid_input(
                "Stockfish skill must be between 0 and 20",
            ));
        }
        self.send(&format!("setoption name Skill Level value {skill}"))?;
        self.ready()
    }

    pub fn new_game(&mut self) -> Result<(), LibChessError> {
        self.send("ucinewgame")?;
        self.ready()
    }

    pub fn analyse(
        &mut self,
        initial_fen: &str,
        moves: &[String],
        move_time: Duration,
    ) -> Result<EngineAnalysis, LibChessError> {
        let position = if initial_fen == "startpos" {
            if moves.is_empty() {
                "position startpos".to_owned()
            } else {
                format!("position startpos moves {}", moves.join(" "))
            }
        } else if moves.is_empty() {
            format!("position fen {initial_fen}")
        } else {
            format!("position fen {initial_fen} moves {}", moves.join(" "))
        };
        self.send(&position)?;
        let millis = move_time.as_millis().clamp(1, 60_000);
        self.send(&format!("go movetime {millis}"))?;

        let deadline = Instant::now() + move_time + SEARCH_GRACE;
        let mut analysis = EngineAnalysis::default();
        loop {
            let line = self.receive_until(deadline, "the engine search")?;
            if line.starts_with("info ") {
                merge_info(&line, &mut analysis);
            }
            if let Some(rest) = line.strip_prefix("bestmove ") {
                let best = rest.split_ascii_whitespace().next().unwrap_or("(none)");
                analysis.best_move = (best != "(none)").then(|| best.to_owned());
                return Ok(analysis);
            }
        }
    }

    fn ready(&mut self) -> Result<(), LibChessError> {
        self.send("isready")?;
        let deadline = Instant::now() + READY_TIMEOUT;
        loop {
            if self.receive_until(deadline, "engine readiness")? == "readyok" {
                return Ok(());
            }
        }
    }

    fn send(&mut self, command: &str) -> Result<(), LibChessError> {
        if command.contains(['\r', '\n']) {
            return Err(LibChessError::invalid_input(
                "UCI commands must be a single line",
            ));
        }
        writeln!(self.input, "{command}")
            .and_then(|()| self.input.flush())
            .map_err(|error| engine_error(format!("could not write to Stockfish: {error}"), true))
    }

    fn receive_until(
        &mut self,
        deadline: Instant,
        operation: &str,
    ) -> Result<String, LibChessError> {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(engine_error(
                format!("Stockfish timed out during {operation}"),
                true,
            ));
        }
        match self.output.recv_timeout(remaining) {
            Ok(line) => Ok(line),
            Err(RecvTimeoutError::Timeout) => Err(engine_error(
                format!("Stockfish timed out during {operation}"),
                true,
            )),
            Err(RecvTimeoutError::Disconnected) => Err(engine_error(
                format!("Stockfish stopped unexpectedly during {operation}"),
                true,
            )),
        }
    }
}

impl Drop for UciEngine {
    fn drop(&mut self) {
        let _ = self.send("quit");
        stop_child(&mut self.child);
    }
}

fn merge_info(line: &str, analysis: &mut EngineAnalysis) {
    let tokens = line.split_ascii_whitespace().collect::<Vec<_>>();
    if let Some(score_index) = tokens.iter().position(|token| *token == "score")
        && let (Some(kind), Some(value)) =
            (tokens.get(score_index + 1), tokens.get(score_index + 2))
    {
        match *kind {
            "cp" => {
                if let Ok(value) = value.parse() {
                    analysis.centipawns = Some(value);
                    analysis.mate = None;
                }
            }
            "mate" => {
                if let Ok(value) = value.parse() {
                    analysis.mate = Some(value);
                    analysis.centipawns = None;
                }
            }
            _ => {}
        }
    }
    if let Some(pv_index) = tokens.iter().position(|token| *token == "pv") {
        let variation = tokens[pv_index + 1..].join(" ");
        if !variation.is_empty() {
            analysis.variation = Some(variation);
        }
    }
}

fn engine_error(message: impl Into<String>, retryable: bool) -> LibChessError {
    LibChessError::new(ErrorKind::Provider, message, retryable)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_latest_uci_score_and_variation() {
        let mut analysis = EngineAnalysis::default();
        merge_info(
            "info depth 8 score cp -24 nodes 500 pv e7e5 g1f3",
            &mut analysis,
        );
        assert_eq!(analysis.centipawns, Some(-24));
        assert_eq!(analysis.mate, None);
        assert_eq!(analysis.variation.as_deref(), Some("e7e5 g1f3"));

        merge_info("info depth 12 score mate 3 pv d8h4", &mut analysis);
        assert_eq!(analysis.centipawns, None);
        assert_eq!(analysis.mate, Some(3));
        assert_eq!(analysis.variation.as_deref(), Some("d8h4"));
    }
}
