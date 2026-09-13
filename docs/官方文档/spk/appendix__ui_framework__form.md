---
source: https://help.synology.com/developer-guide/appendix/ui_framework/form.html
title: Form
fetched: 2026-09-11
---

# Form

## Template

`<v-form />` and `<v-form-item />`

## Form Item API

### Form Item - Props

****``

****

****

****

****

**

****``

****

****

****

****

``

``````

| Prop name | Description | Type | Values | Default |  |  |
|---|---|---|---|---|---|---|
| prop | See: Pass 'prop' to &lt;v-form-item&gt; example | string | - | void 0 |  |  |
| label | Label content. | string | - | void 0 |  |  |
| disableLabel | - | boolean | - | false |  |  |
| disableDescription | - | boolean | - | false |  |  |
| validateDisabledField | If true, the form will validate disabled fields. | boolean | - | false |  |  |
| disableValidation | If true, the form won't validate all the field. | boolean | - | false |  |  |
| hideValidateMessage | If true, validation message won't be shown. | boolean | - | false |  |  |
| hideValidateStatusCls | If true, hide status when validate result is error | boolean | - | false |  |  |
| rules | Validation rules, it will concat form rules if exists.Visit async-validator for more details. | object\ | array | - | void 0 |  |
| help | Text for validation message. | string | - | void 0 |  |  |
| validateStatus | Options: ['validating', 'success', 'warning', 'error']. | string | - | void 0 |  |  |
| defaultValidateTrigger | when rules trigger key is not given, it will use this value as default trigger timing | string | - | 'blur' |  |  |
| immediateValidate | If true, it will instantly validate value with 'change' trigger event | boolean | - | false |  |  |
| showMessage | If true, it will show validation message. | boolean | - | true |  |  |
| hideLabel | If true, it won't reserve space for label. | boolean | - | false |  |  |
| textonly | If true, it will apply display-field style. | boolean | - | false |  |  |
| indent | We apply css variable on --indent | number\ | string | - | 0 |  |
| validateDebouncedTimer | Debounce milliseconds for validation. | number | - | 250 |  |  |
| registerKey | In multiple form-component situation, it can be the identify key for form-component to register on it | string | - | void 0 |  |  |
| validateMessageDisplayMode | - | string | popup, text, form | 'form' |  |  |
| fixInitialValue | - | string | - | void 0 |  |  |
| wrapperFlex | - | string\ | number\ | object | - | void 0 |
| controlFlex | - | string\ | number\ | object | - | void 0 |
| labelFlex | - | string\ | number\ | object | - | void 0 |

### Form Item - Methods

### showPopup

show popup with message. if message is not defined will show the previous message

| Param name | Type | Description |
|---|---|---|
| msg | - | - |

### hidePopup

hide popup

### validate

- return `null` for validated.

-

return `string` for error message.

| Param name | Type | Description |
| ---------- | ------ | ----------- |
| trigger | string | trigger |
| options | object | options |
| extraRules | object | rule |

| Returns Type | Description |
| ----------------- | ----------- |
| Promise`<string>` | |

### resetField

Reset all dirty field to initial value.

### commit

Commit changes.

### resetInvalid

clear validate state and message

### Form Item - Events

****``

| Event name | Properties | Description |
|---|---|---|
| validated | validate Object - payload | Emitted when validated |
| validating | - | - |

### Form Item - Slots

| Name | Description | Bindings |
|---|---|---|
| before | Before input element | - |
| label | label slot |  |
| label-before | label before slot | - |
| label-after | label after slot | - |
| default | Input fields in the form | - |
| status | show display status on validate message | - |
| description | - | - |
| after | After input element | - |

## Form Multiple Item API

### Form Multiple Item - Props

****

````

````

``

``

| Prop name | Description | Type | Values | Default |  |  |  |
|---|---|---|---|---|---|---|---|
| label | Label content. | string | - | void 0 |  |  |  |
| disableLabel | - | boolean | - | false |  |  |  |
| hideLabel | If true, it won't reserve space for label. | boolean | - | false |  |  |  |
| marginSize | The margin between each &lt;div&gt; under &lt;v-form-multiple-item&gt; | string | small, large | 'small' |  |  |  |
| indent | We apply css variable on --indent | number\ | string | - | 0 |  |  |
| gap | space between grids, could be a number or a object or array represent as [horizontal, vertical]{ xs: 5, sm: 10, md: 12, xl: [12, 24] } | object\ | string\ | array\ | number | - | () => ['6px', '6px'] |
| flexWrap | flex wrap or not | object\ | boolean | - | false |  |  |
| flexAlign | - | object\ | boolean | - | void 0 |  |  |
| flexJustify | - | object\ | boolean | - | void 0 |  |  |
| flex | - | string | - | FOLLOW_FORM |  |  |  |
| labelFlex | - | string\ | number\ | object | - | void 0 |  |
| itemsWrapperFlex | - | string\ | number\ | object | - | void 0 |  |

### Form Multiple Item - Slots

| Name | Description | Bindings |
|---|---|---|
| label | label slot | - |
| label-before | label before slot | - |
| label-after | label after slot | - |
| default | - | - |

## Form API

### Form - Props

**

****``

````

| Prop name | Description | Type | Values | Default |  |
|---|---|---|---|---|---|
| flex | open flex form to cover mobile layout, | boolean\ | string | - | false |
| layoutOrder | - | number | - | 0 |  |
| v-model | Form values. | object | - | - |  |
| rules | Validation rules.Visit async-validator for more details. | object | - | - |  |
| direction | Form list directionOptions: ['horizontal', 'vertical']when direction is adaptive, it will choose direction by breakpoint | object\ | string | - | () => ({ 'xxs': FORM_DIRECTION.VERTICAL, 'xxxl': FORM_DIRECTION.HORIZONTAL}) |
| validateMessageDisplayMode | - | string | popup, text | 'popup' |  |

### Form - Methods

### findField

The `name` attribute of HTML Element

| Param name | Type | Description |
|---|---|---|
| name | string | - |

``

| Returns Type | Description |
|---|---|
| vnode | vnode of the field. |

### resetFields

Reset all dirty field to initial value.

### validate

Is all fields valid?

| Param name | Type | Description |
|---|---|---|
| trigger | string | - |

| Returns Type | Description |
|---|---|
| Promise\ |  |

### validateField

Form has modified field?

| Param name | Type | Description |
|---|---|---|
| prop | - | - |

| Returns Type | Description |
|---|---|
| Boolean |  |

### isDirty

Are all form-items dirty

| Returns Type | Description |
|---|---|
| Boolean |  |

### commit

Commit changes.

### Form - Events

****``

****``

| Event name | Properties | Description |
|---|---|---|
| submit | event EventObject - undefined | Emitted when the form is submitted. |
| validated | validate Object - payload | Emitted when validated |

### Form - Slots

| Name | Description | Bindings |
|---|---|---|
| default | Input fields in the form | - |

## Incremental Form Multiple Item API

### Incremental Form Multiple Item - Props

****

``

| Prop name | Description | Type | Values | Default |  |  |
|---|---|---|---|---|---|---|
| iconType | - | string | - | ICON_TYPE.FOLLOW_MANAGER |  |  |
| label | Label content. | string | - | void 0 |  |  |
| disableLabel | - | boolean | - | false |  |  |
| hideLabel | If true, it won't reserve space for label. | boolean | - | false |  |  |
| indent | We apply css variable on --indent | number | - | 0 |  |  |
| items | - | array | - | [] |  |  |
| minItemsLength | - | number | - | 0 |  |  |
| maxItemsLength | - | number | - | void 0 |  |  |
| addText | - | string | - | function() { return this._i18n('common', 'add_field');} |  |  |
| disabledAddButton | - | boolean | - | void 0 |  |  |
| disabledRemoveButton | - | boolean | - | false |  |  |
| gap | - | object\ | string\ | array | - | () => [FORM_BASIC_GAP, FORM_BASIC_GAP] |
| columns | define grid columns number | number | - | 24 |  |  |
| labelFlex | - | string\ | number\ | object | - | void 0 |
| itemsWrapperFlex | - | string\ | number\ | object | - | void 0 |

### Incremental Form Multiple Item - Events

| Event name | Properties | Description |
|---|---|---|
| update:items | - | - |
| remove-item | - | - |
| add-item | - | - |

### Incremental Form Multiple Item - Slots

| Name | Description | Bindings |
|---|---|---|
| label | label slot | - |
| label-before | label before slot | - |
| label-after | label after slot | - |
| default | - | - |
| remove-field | - |  |
| actions | - | - |
