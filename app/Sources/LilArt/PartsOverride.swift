import Foundation
import ModelZoo

/// Has the engine use other files for parts of one model (VAE, text encoder, …), for one run.
///
/// With every request the kit sends the engine its description of the model to run, taken
/// from `ModelZoo`, and the engine goes by that description rather than its own for the length
/// of the request. Swapping a part's file name in it is the whole trick: the engine is not
/// restarted and its own list of models (custom.json) is never touched.
enum PartsOverride {
  /// Whether this side knows the model's description (a catalog model it never opened does not).
  static func isKnown(_ model: String) -> Bool { ModelZoo.specificationForModel(model) != nil }

  /// This side reads custom.json once, when it starts: a model converted since is unknown to it,
  /// and its description would not travel with the request. Reads it from the file then.
  static func prime(_ model: String) {
    guard ModelZoo.specificationForModel(model) == nil,
      let data = try? Data(contentsOf: ModelsFolder.url.appendingPathComponent("custom.json"))
    else { return }
    struct Lenient: Decodable {
      let value: ModelZoo.Specification?
      init(from decoder: Decoder) throws { value = try? ModelZoo.Specification(from: decoder) }
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let list = try? decoder.decode([Lenient].self, from: data),
      let found = list.compactMap(\.value).first(where: { $0.file == model })
    else { return }
    ModelZoo.overrideMapping[model] = found
  }

  enum Failure: LocalizedError {
    case unknownModel

    var errorDescription: String? {
      "движок не знает эту модель, поэтому свои VAE и кодировщики к ней не подключить"
    }
  }

  /// `takesImage` set: the person said the model animates a picture (or does not), whatever
  /// its description says; the engine is told so through the description it gets.
  static func using<T>(
    _ parts: [ModelParts.Slot: String], takesImage: Bool? = nil, for model: String,
    _ body: () async throws -> T
  ) async throws -> T {
    prime(model)
    guard !parts.isEmpty || takesImage != nil else { return try await body() }
    guard var specification = ModelZoo.specificationForModel(model) else {
      throw Failure.unknownModel
    }
    if let takesImage {
      if takesImage {
        specification.modifier = .inpainting
      } else if specification.modifier == .inpainting {
        specification.modifier = nil
      }
    }
    for (slot, file) in parts {
      switch slot {
      case .autoencoder: specification.autoencoder = file
      case .textEncoder: specification.textEncoder = file
      case .clipEncoder: specification.clipEncoder = file
      case .t5Encoder: specification.t5Encoder = file
      case .imageEncoder: specification.imageEncoder = file
      }
    }
    let previous = ModelZoo.overrideMapping[model]
    ModelZoo.overrideMapping[model] = specification
    defer { ModelZoo.overrideMapping[model] = previous }
    return try await body()
  }
}
