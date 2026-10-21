/// Where an `ImageAsset`'s file came from (requirements I1, I2).
public enum ImageSource: String, Codable, Sendable, CaseIterable {
    case generated
    case library
    case camera
}
