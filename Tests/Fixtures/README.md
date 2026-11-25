The portrait speech fixture is synthetic Danish speech generated for the tests.
It contains no personal recording.

Generated with eSpeak-ng using Danish at 170 words per minute, then converted
to mono, signed 16-bit PCM at 16 kHz.

The text is "Hej. Jeg læser en lille tekst, mens figuren taler og blinker.
Nu prøver vi igen. Tak for i dag."

The Cubism integration test plays the clip through ChristelPlayer, including
its actual AVAudioPlayer metering, and checks blink, mouth and breath pixels.
Live synthesis and voice quality remain separate device checks.
