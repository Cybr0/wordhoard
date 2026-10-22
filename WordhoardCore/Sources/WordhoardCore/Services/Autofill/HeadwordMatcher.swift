import Foundation
import NaturalLanguage

/// Decides whether an example sentence contains the headword or an inflection of it (plan 2.9,
/// requirement A2). The model substitutes a synonym for the headword in about five words per
/// regression run (ADR 0001), so every example is checked in code before it is kept.
///
/// Pure and stateless; safe from any isolation. Ported from the spike runner's `containsHeadword`:
/// every word of the headword must appear as a sentence token that starts with its stem, or as a
/// listed irregular form; this port adds `NLTagger` lemmas, so *went* finds *go* without a table
/// entry. When the tagger yields no lemma for a token, the stem rule and the table alone decide.
/// Prefix matching accepts *bookkeeper* for *book*; a false positive costs less than a dropped
/// example. Multi-word headwords match with their words anywhere: *looked it up* matches *look up*.
public enum HeadwordMatcher {
    /// `true` when every word of `headword` is present in `sentence` as itself, an inflection or a
    /// listed irregular form. A blank headword or sentence is `false`.
    public static func contains(headword: String, in sentence: String) -> Bool {
        let parts = tokens(headword)
        let sentenceTokens = tokens(sentence)
        guard !parts.isEmpty, !sentenceTokens.isEmpty else { return false }
        var lemmas: Set<String>?
        for part in parts {
            let stems = stems(of: part)
            let irregular = irregularForms[part] ?? []
            if sentenceTokens.contains(where: { token in
                stems.contains { token.hasPrefix($0) } || irregular.contains(token)
            }) {
                continue
            }
            if lemmas == nil {
                lemmas = Self.lemmas(of: sentence)
            }
            guard lemmas?.contains(part) == true else { return false }
        }
        return true
    }

    /// The stricter match for back-translations (plan 2.10): `true` when every word of `headword` is a
    /// token of `text` itself, a regular inflection of it (`-s`, `-es`, `-ed`, `-d`, `-ing`, after the
    /// stem rules or with the last letter doubled), a listed irregular form, or the English lemma of a
    /// token. No bare prefix: *upward* is not *up*, so "to look upward" does not confirm *look up*.
    public static func containsLemma(of headword: String, in text: String) -> Bool {
        let parts = tokens(headword)
        let textTokens = Set(tokens(text))
        guard !parts.isEmpty, !textTokens.isEmpty else { return false }
        var lemmas: Set<String>?
        for part in parts {
            if !textTokens.isDisjoint(with: inflections(of: part)) {
                continue
            }
            if lemmas == nil {
                lemmas = Self.lemmas(of: text)
            }
            guard lemmas?.contains(part) == true else { return false }
        }
        return true
    }

    /// `word`, its regular inflections and its listed irregular forms.
    static func inflections(of word: String) -> Set<String> {
        var forms: Set<String> = irregularForms[word] ?? []
        for stem in stems(of: word) {
            for suffix in ["", "s", "es", "ed", "d", "ing"] {
                forms.insert(stem + suffix)
            }
        }
        if let last = word.last, !"aeiouy".contains(last) {
            forms.insert(word + String(last) + "ed")
            forms.insert(word + String(last) + "ing")
        }
        return forms
    }

    /// Lowercased, NFC-composed tokens of letters, digits and apostrophes; punctuation splits.
    static func tokens(_ text: String) -> [String] {
        text.precomposedStringWithCanonicalMapping
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
    }

    /// The prefixes an inflection of `word` may start with: the word, the word minus a final *e*
    /// (*make* → *making*), and *y* → *i* (*try* → *tries*, *tried*).
    static func stems(of word: String) -> [String] {
        var stems = [word]
        if word.count >= 4, word.hasSuffix("e") {
            stems.append(String(word.dropLast()))
        }
        if word.count >= 3, word.hasSuffix("y") {
            stems.append(String(word.dropLast()) + "i")
        }
        return stems
    }

    /// Lowercased lemmas of every word in `sentence`, from the English lemma tagger.
    static func lemmas(of sentence: String) -> Set<String> {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = sentence
        let range = sentence.startIndex ..< sentence.endIndex
        tagger.setLanguage(.english, range: range)
        var lemmas: Set<String> = []
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace]
        tagger.enumerateTags(in: range, unit: .word, scheme: .lemma, options: options) { tag, _ in
            if let lemma = tag?.rawValue {
                lemmas.insert(lemma.lowercased())
            }
            return true
        }
        return lemmas
    }

    /// Irregular inflections the stem rule misses, lemma → forms. Verbs the regression list and
    /// everyday English need, plus irregular plurals; the lemma tagger covers the long tail.
    static let irregularForms: [String: Set<String>] = [
        "be": ["am", "is", "are", "was", "were", "been", "being"],
        "bear": ["bore", "borne", "born"],
        "beat": ["beaten"],
        "become": ["became"],
        "begin": ["began", "begun"],
        "bend": ["bent"],
        "bite": ["bit", "bitten"],
        "bleed": ["bled"],
        "blow": ["blew", "blown"],
        "break": ["broke", "broken"],
        "bring": ["brought"],
        "build": ["built"],
        "buy": ["bought"],
        "can": ["could"],
        "catch": ["caught"],
        "choose": ["chose", "chosen"],
        "come": ["came"],
        "deal": ["dealt"],
        "dig": ["dug"],
        "do": ["does", "did", "done"],
        "draw": ["drew", "drawn"],
        "drink": ["drank", "drunk"],
        "drive": ["drove", "driven"],
        "eat": ["ate", "eaten"],
        "fall": ["fell", "fallen"],
        "feed": ["fed"],
        "feel": ["felt"],
        "fight": ["fought"],
        "find": ["found"],
        "flee": ["fled"],
        "fly": ["flew", "flown"],
        "forget": ["forgot", "forgotten"],
        "forgive": ["forgave", "forgiven"],
        "freeze": ["froze", "frozen"],
        "get": ["got", "gotten"],
        "give": ["gave", "given"],
        "go": ["went", "gone"],
        "grow": ["grew", "grown"],
        "hang": ["hung"],
        "have": ["has", "had"],
        "hear": ["heard"],
        "hide": ["hid", "hidden"],
        "hold": ["held"],
        "keep": ["kept"],
        "know": ["knew", "known"],
        "lead": ["led"],
        "leave": ["left"],
        "lend": ["lent"],
        "lie": ["lay", "lain"],
        "light": ["lit"],
        "lose": ["lost"],
        "make": ["made"],
        "may": ["might"],
        "mean": ["meant"],
        "meet": ["met"],
        "pay": ["paid"],
        "read": ["read"],
        "ride": ["rode", "ridden"],
        "ring": ["rang", "rung"],
        "rise": ["rose", "risen"],
        "run": ["ran"],
        "say": ["said"],
        "see": ["saw", "seen"],
        "seek": ["sought"],
        "sell": ["sold"],
        "send": ["sent"],
        "set": ["set"],
        "shake": ["shook", "shaken"],
        "shall": ["should"],
        "shoot": ["shot"],
        "show": ["shown"],
        "shrink": ["shrank", "shrunk"],
        "sing": ["sang", "sung"],
        "sink": ["sank", "sunk"],
        "sit": ["sat"],
        "sleep": ["slept"],
        "slide": ["slid"],
        "speak": ["spoke", "spoken"],
        "spend": ["spent"],
        "spin": ["spun"],
        "stand": ["stood"],
        "steal": ["stole", "stolen"],
        "stick": ["stuck"],
        "sting": ["stung"],
        "strike": ["struck"],
        "sweep": ["swept"],
        "swim": ["swam", "swum"],
        "swing": ["swung"],
        "take": ["took", "taken"],
        "teach": ["taught"],
        "tear": ["tore", "torn"],
        "tell": ["told"],
        "think": ["thought"],
        "throw": ["threw", "thrown"],
        "understand": ["understood"],
        "wake": ["woke", "woken"],
        "wear": ["wore", "worn"],
        "weep": ["wept"],
        "will": ["would"],
        "win": ["won"],
        "write": ["wrote", "written"],
        "child": ["children"],
        "foot": ["feet"],
        "goose": ["geese"],
        "half": ["halves"],
        "knife": ["knives"],
        "leaf": ["leaves"],
        "life": ["lives"],
        "loaf": ["loaves"],
        "man": ["men"],
        "mouse": ["mice"],
        "person": ["people"],
        "self": ["selves"],
        "shelf": ["shelves"],
        "thief": ["thieves"],
        "tooth": ["teeth"],
        "wife": ["wives"],
        "wolf": ["wolves"],
        "woman": ["women"],
    ]
}
