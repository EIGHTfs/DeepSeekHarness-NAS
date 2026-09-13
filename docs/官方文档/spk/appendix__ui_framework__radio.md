---
source: https://help.synology.com/developer-guide/appendix/ui_framework/radio.html
title: Radio
fetched: 2026-09-11
---

# Radio

## Template

`<v-radio />` and `<v-radio-group />`

## Radio Group API

### Radio Group - Props

``

``

``

``
****

****

``

| Prop name | Description | Type | Values | Default |  |  |
|---|---|---|---|---|---|---|
| subscribeField | Subscribe specific register-key form-item on ancestor | string | - | void 0 |  |  |
| activeFormItem | do not register on form-item | boolean | - | true |  |  |
| enterKey | used for enterkeyhint attribute, and will change behavior when enter key is pressed | string | - | EnterHint.Enter |  |  |
| boundaryComponentName | - | string | - | 'PortalTarget' |  |  |
| v-model | The &lt;v-radio&gt; in the group which have the same value will be selected. | string\ | number\ | boolean | - | '' |
| data | The radio-group will generate &lt;v-radio&gt;s by referencing this prop.Note: This prop will be ignored if there are contents in the slot. | RadioGroupData | - | [] |  |  |
| disabled | If true, the whole group will be disabled. | boolean | - | false |  |  |
| name | Name of the component. | string | - | function() { return syno-${this.uuid};} |  |  |
| deactiveChildrenFormItems | deactive all children form-itemsThis will prevent single radio button to register a form-item which should be radio-group field | func\ | boolean | - | () => vRadio |  |

### Radio Group - Property

#### RadioGroupData

****

| Attribute | Type | Required | Default | Description |
|---|---|---|---|---|
| text | string | false | - | Text of the radio button |
| value | string | true | - | Value of the radio button |
| disabled | boolean | false | false | If true, the radio button will be disabled |

### Radio Group - Events

****

****

| Event name | Properties | Description |  |  |
|---|---|---|---|---|
| focus-next-field | - | - |  |  |
| focus-prev-field | - | - |  |  |
| blur | - | - |  |  |
| input | value `string \ | number \ | boolean` - undefined | Emitted when value is changed. |
| change | value `string \ | number \ | boolean` - undefined | Emitted when value is changed. |

### Radio Group - Slots

| Name | Description | Bindings |
|---|---|---|
| default | - | - |

## Radio API

### Radio - Props

``

``

****

****

``

````

| Prop name | Description | Type | Values | Default |  |  |
|---|---|---|---|---|---|---|
| iconType | - | string | - | ICON_TYPE.FOLLOW_MANAGER |  |  |
| subscribeField | Subscribe specific register-key form-item on ancestor | string | - | void 0 |  |  |
| activeFormItem | do not register on form-item | boolean | - | true |  |  |
| enterKey | used for enterkeyhint attribute, and will change behavior when enter key is pressed | string | - | EnterHint.Enter |  |  |
| boundaryComponentName | - | string | - | 'PortalTarget' |  |  |
| stopPropagation | If true, the click event of the checkbox will stop propagation. | boolean | - | false |  |  |
| value | Value of this radio-button. | string\ | number\ | boolean | - | '' |
| v-model | selected value | string\ | number\ | boolean | - | '' |
| disabled | If true, the component will be disabled. | boolean | - | false |  |  |
| id | ID of the component. | string | - | function() { return syno-${this.uuid};} |  |  |
| name | Name of the component. | string | - | '' |  |  |
| labelColor | Color of label | string | normal, red | 'normal' |  |  |

### Radio - Events

****``

****

****``

****``

| Event name | Properties | Description |  |  |
|---|---|---|---|---|
| focus-next-field | - | - |  |  |
| focus-prev-field | - | - |  |  |
| blur | this VueComponent - undefined | Emitted when the component is blurred. |  |  |
| input | value `string \ | number \ | boolean` - undefined | Emitted when the value is changed. |
| focus | this VueComponent - undefined | Emitted when the component is focused. |  |  |
| click | this VueComponent - undefined | Emitted when the component is clicked. |  |  |

### Radio - Slots

| Name | Description | Bindings |
|---|---|---|
| default | - | - |
