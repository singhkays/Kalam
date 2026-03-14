#!/usr/bin/env swift
import Foundation

// Note: This script assumes it's being run in an environment where it can link
// against the Kalam project or its source files.
// For demonstration, it mocks the engine logic for immediate feedback.

print("--- Kalam Engine CLI Test Runner ---")

let args = CommandLine.arguments
guard args.count > 1 else {
  print("Usage: swift run_engine_test.swift \"your text here\"")
  exit(0)
}

let input = args.dropFirst().joined(separator: " ")

func mockCleanup(_ text: String) -> String {
  var out = text
  let fillers = ["um", "uh", "you know"]
  for f in fillers {
    out = out.replacingOccurrences(of: f, with: "", options: .caseInsensitive)
  }
  
  // Basic scratch that
  if let range = out.range(of: "scratch that", options: .backwards) {
    out = String(out[range.upperBound...])
  }
  
  return out.trimmingCharacters(in: .whitespaces)
}

func mockITN(_ text: String) -> String {
  // Simple number normalization
  return text.replacingOccurrences(of: "one", with: "1")
             .replacingOccurrences(of: "two", with: "2")
}

let afterCleanup = mockCleanup(input)
let final = mockITN(afterCleanup)

print("\nProcessing Pipeline:")
print("[Input]     : \(input)")
print("[Cleanup]   : \(afterCleanup)")
print("[Final]     : \(final)")
print("\n--- Done ---")
