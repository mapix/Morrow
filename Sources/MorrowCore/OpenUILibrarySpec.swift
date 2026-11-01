import Foundation

extension OpenUINativeLibrary {

    public static var librarySpecData: Data {
        var root = (try! JSONSerialization.jsonObject(with: baseLibrarySpecData)) as! [String: Any]
        root["version"] = version
        var schema = root["schema"] as! [String: Any]
        var properties = schema["properties"] as! [String: Any]
        var definitions = schema["$defs"] as! [String: Any]
        var components = root["components"] as! [String: Any]
        for name in ["BarChart", "LineChart", "PieChart"] {
            properties[name] = ["$ref": "#/$defs/" + name]
            definitions[name] = ["type": "object", "properties": ["title": ["type": "string"], "data": ["type": "array", "maxItems": 200, "items": ["type": "object", "properties": ["label": ["type": "string"], "value": ["type": "number"], "series": ["type": "string"]], "required": ["label", "value"]]], "description": ["type": "string"]], "required": ["title", "data"]]
            components[name] = ["signature": name + "(title: string, data: {label: string, value: number, series?: string}[], description?: string)", "description": "Read-only native chart using actual tool data"]
        }
        properties["Steps"] = ["$ref": "#/$defs/Steps"]
        definitions["Steps"] = ["type": "object", "properties": ["title": ["type": "string"], "items": ["type": "array", "maxItems": 20, "items": ["type": "string"]]], "required": ["title", "items"]]
        components["Steps"] = ["signature": "Steps(title: string, items: string[])", "description": "Read-only ordered workflow"]
        schema["properties"] = properties; schema["$defs"] = definitions
        root["schema"] = schema; root["components"] = components
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
    private static let baseLibrarySpecData = Data(#"""
{
  "id": "morrow-native",
  "version": "0.1.0",
  "root": "Stack",
  "schema": {
    "properties": {
      "Stack": {
        "$ref": "#/$defs/Stack"
      },
      "Card": {
        "$ref": "#/$defs/Card"
      },
      "CardHeader": {
        "$ref": "#/$defs/CardHeader"
      },
      "TextContent": {
        "$ref": "#/$defs/TextContent"
      },
      "Text": {
        "$ref": "#/$defs/Text"
      },
      "Markdown": {
        "$ref": "#/$defs/Markdown"
      },
      "Table": {
        "$ref": "#/$defs/Table"
      },
      "Col": {
        "$ref": "#/$defs/Col"
      },
      "Form": {
        "$ref": "#/$defs/Form"
      },
      "FormControl": {
        "$ref": "#/$defs/FormControl"
      },
      "Input": {
        "$ref": "#/$defs/Input"
      },
      "TextArea": {
        "$ref": "#/$defs/TextArea"
      },
      "Choice": {
        "$ref": "#/$defs/Choice"
      },
      "Buttons": {
        "$ref": "#/$defs/Buttons"
      },
      "Button": {
        "$ref": "#/$defs/Button"
      },
      "Citation": {
        "$ref": "#/$defs/Citation"
      }
    },
    "$defs": {
      "Stack": {
        "type": "object",
        "properties": {
          "children": {
            "type": "array",
            "items": {
              "$ref": "#/$defs/Component"
            }
          }
        },
        "required": [
          "children"
        ]
      },
      "Card": {
        "type": "object",
        "properties": {
          "children": {
            "type": "array",
            "items": {
              "$ref": "#/$defs/Component"
            }
          }
        },
        "required": [
          "children"
        ]
      },
      "CardHeader": {
        "type": "object",
        "properties": {
          "title": {
            "type": "string"
          },
          "subtitle": {
            "type": "string"
          }
        },
        "required": [
          "title"
        ]
      },
      "TextContent": {
        "type": "object",
        "properties": {
          "text": {
            "type": "string"
          },
          "style": {
            "type": "string"
          }
        },
        "required": [
          "text"
        ]
      },
      "Text": {
        "type": "object",
        "properties": {
          "text": {
            "type": "string"
          }
        },
        "required": [
          "text"
        ]
      },
      "Markdown": {
        "type": "object",
        "properties": {
          "text": {
            "type": "string"
          }
        },
        "required": [
          "text"
        ]
      },
      "Table": {
        "type": "object",
        "properties": {
          "columns": {
            "type": "array",
            "items": {
              "$ref": "#/$defs/Col"
            }
          }
        },
        "required": [
          "columns"
        ]
      },
      "Col": {
        "type": "object",
        "properties": {
          "label": {
            "type": "string"
          },
          "data": {
            "type": "array",
            "items": {}
          }
        },
        "required": [
          "label",
          "data"
        ]
      },
      "Form": {
        "type": "object",
        "properties": {
          "name": {
            "type": "string"
          },
          "children": {
            "type": "array",
            "items": {
              "$ref": "#/$defs/Component"
            }
          }
        },
        "required": [
          "name",
          "children"
        ]
      },
      "FormControl": {
        "type": "object",
        "properties": {
          "label": {
            "type": "string"
          },
          "child": {
            "$ref": "#/$defs/Component"
          }
        },
        "required": [
          "label"
        ]
      },
      "Input": {
        "type": "object",
        "properties": {
          "name": {
            "type": "string"
          },
          "placeholder": {
            "type": "string"
          },
          "value": {},
          "rules": {
            "type": "object"
          }
        },
        "required": [
          "name"
        ]
      },
      "TextArea": {
        "type": "object",
        "properties": {
          "name": {
            "type": "string"
          },
          "placeholder": {
            "type": "string"
          },
          "value": {},
          "rules": {
            "type": "object"
          }
        },
        "required": [
          "name"
        ]
      },
      "Choice": {
        "type": "object",
        "properties": {
          "name": {
            "type": "string"
          },
          "label": {
            "type": "string"
          },
          "options": {
            "type": "array",
            "items": {}
          },
          "value": {}
        },
        "required": [
          "name",
          "label",
          "options"
        ]
      },
      "Buttons": {
        "type": "object",
        "properties": {
          "children": {
            "type": "array",
            "items": {
              "$ref": "#/$defs/Component"
            }
          },
          "direction": {
            "type": "string"
          }
        },
        "required": [
          "children"
        ]
      },
      "Button": {
        "type": "object",
        "properties": {
          "label": {
            "type": "string"
          },
          "action": {
            "$ref": "#/$defs/ActionExpression"
          },
          "variant": {
            "type": "string"
          }
        },
        "required": [
          "label"
        ]
      },
      "Citation": {
        "type": "object",
        "properties": {
          "sourceId": {
            "type": "string"
          },
          "label": {
            "type": "string"
          }
        },
        "required": [
          "sourceId"
        ]
      },
      "Component": {
        "anyOf": [
          {
            "$ref": "#/$defs/Stack"
          },
          {
            "$ref": "#/$defs/Card"
          },
          {
            "$ref": "#/$defs/CardHeader"
          },
          {
            "$ref": "#/$defs/TextContent"
          },
          {
            "$ref": "#/$defs/Text"
          },
          {
            "$ref": "#/$defs/Markdown"
          },
          {
            "$ref": "#/$defs/Table"
          },
          {
            "$ref": "#/$defs/Col"
          },
          {
            "$ref": "#/$defs/Form"
          },
          {
            "$ref": "#/$defs/FormControl"
          },
          {
            "$ref": "#/$defs/Input"
          },
          {
            "$ref": "#/$defs/TextArea"
          },
          {
            "$ref": "#/$defs/Choice"
          },
          {
            "$ref": "#/$defs/Buttons"
          },
          {
            "$ref": "#/$defs/Button"
          },
          {
            "$ref": "#/$defs/Citation"
          }
        ]
      },
      "ActionExpression": {
        "anyOf": [
          {
            "type": "object",
            "properties": {
              "type": {
                "const": "continue_conversation"
              },
              "context": {}
            },
            "required": [
              "type"
            ]
          },
          {
            "type": "object",
            "properties": {
              "type": {
                "type": "string"
              },
              "params": {
                "type": "object"
              }
            },
            "required": [
              "type"
            ]
          }
        ]
      }
    },
    "actions": {
      "OpenMailSource": {
        "description": "OpenMailSource",
        "params": {
          "type": "object",
          "properties": {
            "sourceId": {
              "type": "string"
            }
          },
          "required": [
            "sourceId"
          ]
        }
      },
      "OpenDraft": {
        "description": "OpenDraft",
        "params": {
          "type": "object",
          "properties": {
            "draftId": {
              "type": "string"
            }
          },
          "required": [
            "draftId"
          ]
        }
      },
      "ConfigureResponder": {
        "description": "ConfigureResponder",
        "params": {
          "type": "object",
          "properties": {},
          "required": []
        }
      },
      "SaveResponder": {
        "description": "SaveResponder",
        "params": {
          "type": "object",
          "properties": {},
          "required": []
        }
      }
    }
  },
  "components": {
    "Stack": {
      "signature": "Stack(children: Component[])",
      "description": "Morrow native Stack"
    },
    "Card": {
      "signature": "Card(children: Component[])",
      "description": "Morrow native Card"
    },
    "CardHeader": {
      "signature": "CardHeader(title: string, subtitle?: string)",
      "description": "Morrow native CardHeader"
    },
    "TextContent": {
      "signature": "TextContent(text: string, style?: string)",
      "description": "Morrow native TextContent"
    },
    "Text": {
      "signature": "Text(text: string)",
      "description": "Morrow native Text"
    },
    "Markdown": {
      "signature": "Markdown(text: string)",
      "description": "Morrow native Markdown"
    },
    "Table": {
      "signature": "Table(columns: Component[])",
      "description": "Morrow native Table"
    },
    "Col": {
      "signature": "Col(label: string, data: unknown[])",
      "description": "Morrow native Col"
    },
    "Form": {
      "signature": "Form(name: string, children: Component[])",
      "description": "Morrow native Form"
    },
    "FormControl": {
      "signature": "FormControl(label: string, child?: Component)",
      "description": "Morrow native FormControl"
    },
    "Input": {
      "signature": "Input(name: string, placeholder?: string, value?: $binding<string>, rules?: {})",
      "description": "Morrow native Input"
    },
    "TextArea": {
      "signature": "TextArea(name: string, placeholder?: string, value?: $binding<string>, rules?: {})",
      "description": "Morrow native TextArea"
    },
    "Choice": {
      "signature": "Choice(name: string, label: string, options: unknown[], value?: $binding<string>)",
      "description": "Morrow native Choice"
    },
    "Buttons": {
      "signature": "Buttons(children: Component[], direction?: string)",
      "description": "Morrow native Buttons"
    },
    "Button": {
      "signature": "Button(label: string, action?: ActionExpression, variant?: string)",
      "description": "Morrow native Button"
    },
    "Citation": {
      "signature": "Citation(sourceId: string, label?: string)",
      "description": "Morrow native Citation"
    }
  },
  "actions": {
    "OpenMailSource": {
      "signature": "OpenMailSource(sourceId: string)",
      "description": "User-initiated native OpenMailSource"
    },
    "OpenDraft": {
      "signature": "OpenDraft(draftId: string)",
      "description": "User-initiated native OpenDraft"
    },
    "ConfigureResponder": {
      "signature": "ConfigureResponder()",
      "description": "User-initiated native ConfigureResponder"
    },
    "SaveResponder": {
      "signature": "SaveResponder()",
      "description": "User-initiated native SaveResponder"
    }
  }
}
"""#.utf8)
}
