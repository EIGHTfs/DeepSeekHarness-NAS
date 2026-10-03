---
source: https://help.synology.com/developer-guide/appendix/ui_framework/input.html
title: Input
fetched: 2026-09-11
---

# Input

## Template

`<v-input />`

## Input API

### Input - Props

``

``

****``

``

****

****

****``

****``

****

****

****

****

****

****

| Prop name | Description | Type | Values | Default |  |
|---|---|---|---|---|---|
| subscribeField | Subscribe specific register-key form-item on ancestor | string | - | void 0 |  |
| activeFormItem | do not register on form-item | boolean | - | true |  |
| enterKey | used for enterkeyhint attribute, and will change behavior when enter key is pressed | string | - | EnterHint.Enter |  |
| boundaryComponentName | - | string | - | 'PortalTarget' |  |
| iconType | - | string | - | ICON_TYPE.FOLLOW_MANAGER |  |
| type | Type of input.Options: ['text', 'textarea', 'password'] | string | - | 'text' |  |
| id | The component's ID. | string | - | function() { return syno-${this.uuid};} |  |
| v-model | The component's value. | string\ | number | - | void 0 |
| placeholder | Text to be shown when the component's value is empty. | string\ | number | - | '' |
| disabled | If true, the component will be disabled. | boolean | - | false |  |
| autosize | If true, the component will be autosized. | boolean\ | object | - | false |
| strengthChecker | See: Password example. | func\ | boolean | - | false |
| mask | See: Mask example. | RegExp\ | func | - | null |
| numberOnly | If true, the component will only accept number. | boolean | - | false |  |
| defaultShowStrengthChecker | If true, the strength checker will always be shown. | boolean | - | false |  |
| maxlength | Maximum value length the component will accept. | number | - | void 0 |  |
| readonly | If true, the component will be readonly. | boolean | - | false |  |
| focusClass | Class name the component will have when it's being focused.If false, it won't get any additional class when being focused. | boolean\ | string | - | 'focused' |
| disableHoverStyle | If true, the component won't get any additional class whent it's being hovered. | boolean | - | false |  |
| fitContainer | If true, you can assign the input width and make inner content to fit the specified width.For Example:<v-input class="my-class" fit-container />.my-class { width: 300px;} | boolean | - | true |  |
| autocomplete | The autocomplete attribute of input | string | - | 'off' |  |
| showPasswordVisibilityIcon | show password visibility icon when type is password | boolean | - | true |  |
| clearable | show clear button | boolean | - | false |  |
| selectOnFocus | select text when focus on textfield | boolean | - | false |  |
| passwordPortalName | - | string | - | () => 'password-portal' + String(Math.round(Math.random() * 10000000)) |  |
| passwordRules | - | array | - | [] |  |
| mobileBreakpoint | - | string\ | boolean | - | 'xxs' |

### Input - Events

****``
****``

****``
****``

****``

****``

****``

| Event name | Properties | Description |
|---|---|---|
| focus-next-field | - | - |
| focus-prev-field | - | - |
| blur | this VueComponent - undefinedevent EventObject - undefined | Emitted when input is blurred |
| input | - | Emitted when native input event happened. |
| focus | - | - |
| strength-check | strength string - undefinedstrengthText string - undefined | Emitted when strength checker is visible. |
| paste | event EventObject - undefined | Emitted when native paste event is triggered. |
| keyup | event EventObject - undefined | Emitted when native keyup event is triggered. |
| keydown | - | - |
| clear | event EventObject - undefined | Emitted when clear button is clicked. |

### Input - Slots

| Name | Description | Bindings |
|---|---|---|
| password-rule-header | - | - |
| suffix-icons | content as input suffix icons | - |
| prefix | content as input prefix, will not work in textarea | - |
| suffix | content as input suffix, will not work in textarea | - |
