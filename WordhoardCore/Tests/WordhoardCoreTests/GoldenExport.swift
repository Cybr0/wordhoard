import Foundation

/// The pinned schema v1 text of `TransferFixture` exported at `TransferFixture.exportedAt` by
/// `TransferFixture.appVersion`: byte for byte what `Exporter` writes. Review by eye against the schema
/// table in issue #36; regenerate only when the format changes on purpose.
enum GoldenExport {
    static let text = """
    {
      "appVersion" : "0.1.0 (1)",
      "exportedAt" : "2025-06-15T15:06:40.000Z",
      "schemaVersion" : 1,
      "settings" : {
        "activeGrammarTopics" : [
          "en.present_perfect",
          "en.second_conditional"
        ],
        "autoGenerateImages" : false,
        "learningLanguage" : "en",
        "nativeLanguage" : "ru"
      },
      "tags" : [
        {
          "id" : "00000000-0000-0000-0000-000000000100",
          "name" : "reading"
        }
      ],
      "words" : [
        {
          "createdAt" : "2023-11-14T22:13:20.125Z",
          "headword" : "book",
          "id" : "00000000-0000-0000-0000-000000000001",
          "learningLanguage" : "en",
          "note" : "from the spike",
          "pronunciation" : "buk",
          "senses" : [
            {
              "antonyms" : [

              ],
              "definition" : "a written work",
              "examples" : [
                {
                  "grammarTopic" : "en.present_perfect",
                  "id" : "00000000-0000-0000-0000-000000000020",
                  "order" : 0,
                  "source" : "auto",
                  "text" : "She has read a book."
                },
                {
                  "grammarTopic" : "en.no_such_topic",
                  "id" : "00000000-0000-0000-0000-000000000021",
                  "order" : 1,
                  "source" : "auto",
                  "text" : "The book is on the table."
                }
              ],
              "fieldSources" : {
                "definition" : "user",
                "synonyms" : "auto"
              },
              "gloss" : "a written work or composition that has been published",
              "id" : "00000000-0000-0000-0000-000000000010",
              "order" : 0,
              "partOfSpeech" : "noun",
              "senseSource" : "wordnet",
              "synonyms" : [
                "volume",
                "tome"
              ],
              "translation" : "книга"
            },
            {
              "antonyms" : [
                "cancel"
              ],
              "definition" : "to reserve",
              "examples" : [
                {
                  "id" : "00000000-0000-0000-0000-000000000022",
                  "order" : 0,
                  "source" : "auto",
                  "text" : "I booked a table for two."
                },
                {
                  "id" : "00000000-0000-0000-0000-000000000023",
                  "order" : 1,
                  "source" : "user",
                  "text" : "Book early."
                }
              ],
              "fieldSources" : {

              },
              "id" : "00000000-0000-0000-0000-000000000011",
              "order" : 1,
              "partOfSpeech" : "verb",
              "synonyms" : [
                "reserve"
              ],
              "translation" : "заранее заказать место",
              "translationIsFallback" : true
            }
          ],
          "tagIDs" : [
            "00000000-0000-0000-0000-000000000100"
          ],
          "updatedAt" : "2023-11-14T22:15:00.500Z"
        },
        {
          "createdAt" : "2023-11-14T22:16:40.000Z",
          "headword" : "apple",
          "id" : "00000000-0000-0000-0000-000000000002",
          "learningLanguage" : "en",
          "senses" : [
            {
              "antonyms" : [

              ],
              "definition" : "a fruit",
              "examples" : [

              ],
              "fieldSources" : {

              },
              "id" : "00000000-0000-0000-0000-000000000012",
              "order" : 0,
              "partOfSpeech" : "other",
              "synonyms" : [

              ]
            }
          ],
          "tagIDs" : [
            "00000000-0000-0000-0000-000000000100"
          ],
          "updatedAt" : "2023-11-14T22:16:40.000Z"
        }
      ]
    }
    """

    static var data: Data {
        Data(text.utf8)
    }
}
