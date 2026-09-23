//! The mobile client decodes these same files (`mobile/Tests/Fixtures`).
//! Each fixture must survive a Rust decode/encode round trip byte-for-byte
//! (as JSON values), so both sides agree on the wire shape.

use serde::{Deserialize, Serialize};
use zeron_doc::commands::SessionCommandPayload;
use zeron_doc::schema::SessionMessageEntry;
use zeron_doc::transcript_delta::TranscriptFrame;
use zeron_proto::{Chat, Session};

fn round_trip<T: Serialize + for<'de> Deserialize<'de>>(name: &str) {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../mobile/Tests/Fixtures/");
    let text = std::fs::read_to_string(format!("{path}{name}.json")).unwrap();
    let wire: serde_json::Value = serde_json::from_str(&text).unwrap();
    let typed: T = serde_json::from_value(wire.clone()).unwrap();
    assert_eq!(serde_json::to_value(&typed).unwrap(), wire, "{name}");
}

#[test]
fn mobile_fixtures_round_trip() {
    round_trip::<Chat>("chat");
    round_trip::<Session>("session");
    round_trip::<SessionMessageEntry>("entry");
    round_trip::<TranscriptFrame>("frame-reset");
    round_trip::<TranscriptFrame>("frame-delta");
    for name in ["run", "steer", "interrupt", "respond"] {
        round_trip::<SessionCommandPayload>(&format!("command-{name}"));
    }
}
