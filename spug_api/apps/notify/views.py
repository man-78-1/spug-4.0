# Copyright: (c) OpenSpug Organization. https://github.com/openspug/spug
# Copyright: (c) <spug.dev@gmail.com>
# Released under the AGPL-3.0 License.
from django.views.generic import View
from apps.notify.models import Notify
from libs import json_response, JsonParser, Argument


class NotifyView(View):
    def get(self, request):
        notifies = Notify.objects.all()
        return json_response(notifies)

    def patch(self, request):
        form, error = JsonParser(
            # type=list 只管外层，元素原样进 id__in；非整数元素会在 Django 内部抛 TypeError，
            # 再被 HandleExceptionMiddleware 兜成 200 且把内部报错透给前端，所以在解析阶段就拒掉
            Argument('ids', type=list, filter=lambda x: all(str(i).isdigit() for i in x), help='参数错误')
        ).parse(request.body)
        if error is None:
            Notify.objects.filter(id__in=form.ids).update(unread=False)
        return json_response(error=error)
