//
//  IngestEngine.swift — REMOVED 2026-06-29.
//
//  This was a parallel re-implementation of the ingest engine. It has been replaced by the
//  graft approach: the v3 UI (`ContentView.bodyV3`) now renders directly over ContentView's
//  REAL, proven engine (activeIngests / startIngest / detection / history). The duplicate
//  engine was the source of the detection/parity bugs and is gone.
//
//  This file is intentionally empty. Delete it from the Xcode project navigator when convenient.
//
