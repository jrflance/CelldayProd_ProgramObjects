--liquibase formatted sql

--changeset MikeCountryman:f2c78e5b-2892-4ca8-a24b-d403abcb1016 stripComments:false runOnChange:true endDelimiter:/
-- =============================================
-- Author:      Mike Countryman
-- Create date: 2022-10-26
-- Description: Determines if a Veriff Consumer Id has previously received a promo
-- =============================================
CREATE OR ALTER PROCEDURE OrderManagment.P_HasVerificationHistory
    @SessionId NVARCHAR(50),
    @OrderNo INT
AS
BEGIN
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    IF (LEN(TRIM(ISNULL(@SessionId, ''))) > 0)
        BEGIN
            SELECT CASE WHEN COUNT(t.Order_No) < 4 THEN 0 ELSE 1 END AS ReturnCode
            FROM (
                SELECT DISTINCT o.Order_No
                FROM dbo.Order_No AS [on]
                JOIN dbo.Orders AS o ON o.Order_No = [on].Order_No
                JOIN dbo.tblOrderItemAddons AS oia ON oia.OrderID = o.ID
                WHERE
                    [on].OrderType_ID IN (59, 60)
                    AND [on].Filled = 1
                    AND [on].Void = 0
                    AND oia.AddonsID IN (358, 359)
                    AND oia.AddonsValue = @SessionId
                    AND [on].AuthNumber <> CAST(@OrderNo AS NVARCHAR(50))
                    AND [on].DateOrdered > GETDATE() - 60
            ) AS t (Order_No)
        END
    ELSE
        SELECT 1 AS ReturnCode
END

-- noqa: disable=all
/
